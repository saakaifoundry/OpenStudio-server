#*******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2016, Alliance for Sustainable Energy, LLC.
# All rights reserved.
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# (1) Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# (2) Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# (3) Neither the name of the copyright holder nor the names of any contributors
# may be used to endorse or promote products derived from this software without
# specific prior written permission from the respective party.
#
# (4) Other than as required in clauses (1) and (2), distributions in any form
# of modifications or other derivative works may not use the "OpenStudio"
# trademark, "OS", "os", or any other confusingly similar designation without
# specific prior written permission from Alliance for Sustainable Energy, LLC.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER, THE UNITED STATES
# GOVERNMENT, OR ANY CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
# EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#*******************************************************************************

class ComputeNode
  include Mongoid::Document
  include Mongoid::Timestamps

  field :node_type, type: String
  field :ip_address, type: String
  field :hostname, type: String
  field :local_hostname, type: String
  field :user, type: String
  field :password, type: String
  field :cores, type: Integer
  field :ami_id, type: String
  field :instance_id, type: String
  field :valid, type: Boolean, default: false

  # Indexes
  index({ hostname: 1 }, unique: true)
  index({ ip_address: 1 }, unique: true)
  index(node_type: 1)

  # Return all the valid IP addresses as a hash in prep for writing to a dataframe
  def self.worker_ips
    worker_ips_hash = {}
    worker_ips_hash[:worker_ips] = []

    ComputeNode.where(valid: true).each do |node|
      if node.node_type == 'server'
        (1..node.cores).each { |_i| worker_ips_hash[:worker_ips] << 'localhost' }
      else
        (1..node.cores).each { |_i| worker_ips_hash[:worker_ips] << node.ip_address }
      end
    end
    Rails.logger.info("worker ip hash: #{worker_ips_hash}")

    worker_ips_hash
  end

  # New method to download files from the remote systems.  This method flips the download around and favors
  # looking at which points are on the compute node and download the files that way instead of trying to find which
  # compute node the data point was run.
  #
  # This currently works because the user that runs the analysis is ROOT (via delayed jobs).
  # Security-wise, make delayed_jobs run as an analysis user.
  def self.download_all_results(analysis_id = nil)
    # Get the analysis if it exists
    analysis = analysis_id.nil? ? nil : Analysis.find(analysis_id)

    # What is the maximum number of cores that we want this to run on?
    cns = ComputeNode.all
    Parallel.each(cns, in_threads: ComputeNode.count) do |cn|
      ip_address_override = cn.node_type == 'server' ? 'localhost' : cn.ip_address

      Rails.logger.info "Checking for points on #{ip_address_override}"

      # find which data points are complete on the compute node
      dps = nil
      if analysis
        dps = analysis.data_points.and({ download_status: 'na' }, status: 'completed').or({ ip_address: cn.ip_address }, internal_ip_address: cn.ip_address)
      else
        dps = DataPoint.and({ download_status: 'na' }, status: 'completed').or({ ip_address: cn.ip_address }, internal_ip_address: cn.ip_address)
      end

      if dps.count > 0
        # find the right key -- reminder that this works becaused delayed_job is root.
        session = Net::SSH.start(ip_address_override, cn.user, keys: ["/home/#{cn.user}/.ssh/id_rsa"])

        dps.each do |dp|
          st = Time.now
          Rails.logger.info "Trying to download #{dp.id}"
          remote_file_exists, remote_file_downloaded, local_filename = cn.download_result(session, dp.analysis.id, dp.id)

          # now add the data point path to the database to get it via the server
          if remote_file_exists && remote_file_downloaded
            dp.openstudio_datapoint_file_name = local_filename
          elsif remote_file_exists
            dp.openstudio_datapoint_file_name = nil
            dp.download_information = 'failed to download the file'
          else
            dp.download_information = 'file did not exist on remote system or could not connect to remote system'
          end

          dp.finalize_data_point
          dp.download_status = 'completed'
          dp.save!
          Rails.logger.info "Saved downloaded file in #{(Time.now - st)}"
        end
      end
    end
  end

  # Download/move the results
  def download_result(session, analysis_id, data_point_id)
    remote_file_downloaded = false
    remote_file_exists = false
    local_filename = nil

    remote_filepath = "/mnt/openstudio/analysis_#{analysis_id}"
    remote_filename = "#{remote_filepath}/data_point_#{data_point_id}/data_point_#{data_point_id}.zip"
    remote_datapoint_path = "#{remote_filepath}/data_point_#{data_point_id}"
    remote_filename_reports = "#{remote_filepath}/data_point_#{data_point_id}/data_point_#{data_point_id}_reports.zip"
    local_filepath = "/mnt/openstudio/analysis_#{analysis_id}"
    local_filename = "#{local_filepath}/data_point_#{data_point_id}.zip"
    local_filename_reports = "#{local_filepath}/data_point_#{data_point_id}_reports.zip"

    # make sure that the local path exists -- NL: this should always exist as the copy_data_to_workers creates the folder
    # FileUtils.mkdir_p(local_filepath)

    if node_type == 'server'
      Rails.logger.info "looks like this is on the server node, just moving #{remote_filename} to #{local_filename}"
      Rails.logger.info "#{remote_filename} exists... moving to new location"
      FileUtils.mv(remote_filename, local_filename) if File.exist? remote_filename
      FileUtils.mv(remote_filename_reports, local_filename_reports) if File.exist? remote_filename_reports

      remote_file_downloaded = true
      remote_file_exists = true
    else
      Rails.logger.info "Zip file on worker node. scp over to server #{remote_filename} to #{local_filename}"
      a, b = scp_download_file(session, remote_filename_reports, local_filename_reports, remote_datapoint_path)
      remote_file_exists, remote_file_downloaded = scp_download_file(session, remote_filename, local_filename, remote_datapoint_path)

      # unzip the contents of the remote file if it existed
      if a && b
        Rails.logger.info 'Reports zip downloaded'
        local_datapoint_path = "#{local_filepath}/data_point_#{data_point_id}"
        FileUtils.mkdir_p(local_datapoint_path)
        unzip_reports = "cd #{local_filepath} && unzip -o #{local_filename_reports} -d #{local_datapoint_path}"
        Rails.logger.info "Extracting reports zip with command: #{unzip_reports}"
        shell_result = `#{unzip_reports}`
      end
    end

    [remote_file_exists, remote_file_downloaded, local_filename]
  end

  # Report back the system inforamtion of the node for debugging purposes
  def self.system_information
    # # if Rails.env == "development"  #eventually set this up to be the flag to switch between varying environments
    #
    # # end
    #
    # # TODO: move this to a worker init because this is hitting API limits on amazon
    # Socket.gethostname =~ /os-.*/ ? local_host = true : local_host = false
    #
    # # go through the worker node
    # ComputeNode.all.each do |node|
    #   if local_host
    #     node.ami_id = 'Vagrant'
    #     node.instance_id = 'Vagrant'
    #   else
    #     # TODO: convert this all over to Facter -- acutally remove this!
    #     #   ex: @datapoint.ami_id = m['ami-id'] ? m['ami-id'] : 'unknown'
    #     #   ex: @datapoint.instance_id = m['instance-id'] ? m['instance-id'] : 'unknown'
    #     #   ex: @datapoint.hostname = m['public-hostname'] ? m['public-hostname'] : 'unknown'
    #     #   ex: @datapoint.local_hostname = m['local-hostname'] ? m['local-hostname'] : 'unknown'
    #
    #     if node.node_type == 'server'
    #       node.ami_id = `curl -sL http://169.254.169.254/latest/meta-data/ami-id`
    #       node.instance_id = `curl -sL http://169.254.169.254/latest/meta-data/instance-id`
    #     else
    #       # have to communicate with the box to get the instance information (ideally this gets pushed from who knew)
    #       Net::SSH.start(node.ip_address, node.user, password: node.password) do |session|
    #         # Rails.logger.info(self.inspect)
    #
    #         logger.info 'Checking the configuration of the worker nodes'
    #         session.exec!('curl -sL http://169.254.169.254/latest/meta-data/ami-id') do |_channel, _stream, data|
    #           Rails.logger.info("Worker node reported back #{data}")
    #           node.ami_id = data
    #         end
    #         session.loop
    #
    #         session.exec!('curl -sL http://169.254.169.254/latest/meta-data/instance-id') do |_channel, _stream, data|
    #           Rails.logger.info("Worker node reported back #{data}")
    #           node.instance_id = data
    #         end
    #         session.loop
    #       end
    #
    #     end
    #   end
    #
    #   node.save!
    # end
  end

  def scp_download_file(session, remote_file, local_file, remote_file_path)
    remote_file_exists = false
    remote_file_downloaded = false

    # Timeout After 2 Minutes / 120 seconds
    retries = 0
    begin
      Timeout.timeout(120) do
        Rails.logger.info 'Checking if the remote file exists'
        session.exec!("if [ -e '#{remote_file}' ]; then echo -n 'true'; else echo -n 'false'; fi") do |_channel, _stream, data|
          # Rails.logger.info("Check remote file data is #{data}")
          remote_file_exists = true if data == 'true'
        end
        session.loop

        Rails.logger.info "Remote file exists flag is '#{remote_file_exists}' for '#{remote_file}'"
        if remote_file_exists
          Rails.logger.info "Downloading #{remote_file} to #{local_file}"
          if session.scp.download!(remote_file, local_file, preserve: true)
            remote_file_downloaded = true
          else
            remote_file_downloaded = false
            Rails.logger.info 'ERROR trying to download data point from remote worker'
          end

          if remote_file_downloaded
            Rails.logger.info 'Deleting data point from remote worker'
            session.exec!("cd #{remote_file_path} && rm -f #{remote_file}") do |_channel, _stream, _data|
            end
            session.loop
          end
        end
      end
    rescue Timeout::Error
      Rails.logger.error 'TimeoutError trying to download data point from remote server'
      retry if (retries += 1) <= 3
    rescue => e
      Rails.logger.error "Exception while trying to download data point from remote server #{e.message}"
      retry if (retries += 1) <= 3
    end

    # return both booleans
    [remote_file_exists, remote_file_downloaded]
  end
end
