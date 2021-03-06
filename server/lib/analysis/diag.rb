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

class Analysis::Diag
  include Analysis::Core # pivots and static vars

  def initialize(analysis_id, analysis_job_id, options = {})
    # Setup the defaults for the Analysis.  Items in the root are typically used to control the running of
    #   the script below and are not necessarily persisted to the database.
    #   Options under problem will be merged together and persisted into the database.  The order of
    #   preference is objects in the database, objects passed via options, then the defaults below.
    #   Parameters posted in the API become the options hash that is passed into this initializer.
    defaults = {
      skip_init: false,
      run_data_point_filename: 'run_openstudio_workflow.rb',
      problem: {
        random_seed: 1979,
        algorithm: {
          number_of_samples: 2,
          experiment_type: 'diagonal',
          run_baseline: 1
        }
      }
    }.with_indifferent_access # make sure to set this because the params object from rails is indifferential
    @options = defaults.deep_merge(options)

    @analysis_id = analysis_id
    @analysis_job_id = analysis_job_id
  end

  # Perform is the main method that is run in the background.  At the moment if this method crashes
  # it will be logged as a failed delayed_job and will fail after max_attempts.
  def perform
    @analysis = Analysis.find(@analysis_id)

    # get the analysis and report that it is running
    @analysis_job = Analysis::Core.initialize_analysis_job(@analysis, @analysis_job_id, @options)

    # reload the object (which is required) because the subdocuments (jobs) may have changed
    @analysis.reload

    # Create an instance for R
    @r = Rserve::Simpler.new

    begin
      Rails.logger.info "Initializing analysis for #{@analysis.name} with UUID of #{@analysis.uuid}"
      Rails.logger.info "Setting up R for #{self.class.name}"
      # TODO: need to move this to the module class
      @r.converse('setwd("/mnt/openstudio")')

      # make this a core method
      Rails.logger.info "Setting R base random seed to #{@analysis.problem['random_seed']}"
      @r.converse("set.seed(#{@analysis.problem['random_seed']})")

      pivot_array = Variable.pivot_array(@analysis.id, @r)
      
      Rails.logger.info "pivot_array: #{pivot_array}"

      selected_variables = Variable.variables(@analysis.id)
      Rails.logger.info "Found #{selected_variables.count} variables to perform diag"

      # generate the probabilities for all variables as column vectors
      @r.converse("print('starting diag')")
      samples = nil
      var_types = nil
      Rails.logger.info 'Starting sampling'
      diag = Analysis::R::Diag.new(@r)
      if @analysis.problem['algorithm']['experiment_type'] == 'diagonal'
        if selected_variables.count > 0
          samples, var_types = diag.diagonal(selected_variables, @analysis.problem['algorithm']['number_of_samples'],@analysis.problem['algorithm']['run_baseline'])

          # Do the work to mash up the samples and pivot variables before creating the data points
          Rails.logger.info "Samples are #{samples}"
          samples = hash_of_array_to_array_of_hash(samples)
          Rails.logger.info "Flipping samples around yields #{samples}"
        else
          samples = []
          var_types = []
        end
      else
        fail 'no experiment type defined (diagonal)'
      end

      Rails.logger.info 'Fixing Pivot dimension'
      if selected_variables.count > 0
        samples = add_pivots(samples, pivot_array)
      else
        new_samples = []
        if pivot_array.size > 0
          pivot_array.each do |pivot|
            new_samples << pivot
          end
          samples = new_samples
        end 
      end
      Rails.logger.info "Finished adding the pivots resulting in #{samples}"

      # Add the data points to the database
      isample = 0
      samples.uniq.each do |sample| # do this in parallel
        isample += 1
        dp_name = "diag Autogenerated #{isample}"
        dp = @analysis.data_points.new(name: dp_name)
        dp.set_variable_values = sample
        dp.save!

        Rails.logger.info("Generated data point #{dp.name} for analysis #{@analysis.name}")
        Rails.logger.info("UUID #{dp.uuid}")
        Rails.logger.info("variable values: #{dp.set_variable_values}")
      end
    rescue => e
      log_message = "#{__FILE__} failed with #{e.message}, #{e.backtrace.join("\n")}"
      puts log_message
      @analysis.status_message = log_message
      @analysis.save!
    ensure
      # Only set this data if the analysis was NOT called from another analysis
      unless @options[:skip_init]
        @analysis_job.end_time = Time.now
        @analysis_job.status = 'completed'
        @analysis_job.save!
        @analysis.reload
      end
      @analysis.save!

      Rails.logger.info "Finished running analysis '#{self.class.name}'"
    end
  end

  # Since this is a delayed job, if it crashes it will typically try multiple times.
  # Fix this to 1 retry for now.
  def max_attempts
    1
  end
end
