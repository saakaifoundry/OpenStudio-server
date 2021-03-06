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

name 'openstudio-server'
description 'Install and configure OpenStudio for use with Ruby on Rails'

run_list([
  # Default iptables setup on all servers.
  'recipe[openstudio_server::users]',  # Run this before R and before openstudio bashprofile and base
  'role[base]',
  'role[mongodb]',
  'role[r-project]',
  'role[openstudio]',
  'role[radiance]',
  'role[web_base]',
  'recipe[openstudio_server::bashprofile]',
  'recipe[openstudio_server::bundle]', # install the bundle first to get rails for apache passenger
  'role[passenger_apache]',
  'recipe[openstudio_server]',
  'recipe[openstudio_server::worker_data]'
])

default_attributes(
  openstudio_server: {
    ruby_path: '/opt/rbenv/shims', # this is needed for the delayed_job and R runs service. Where is the ruby binary (in the shims)?
    server_path: '/var/www/rails/openstudio',
    rails_environment: 'development'
  }
)

override_attributes(
  r: {
    rserve_start_on_boot: true,
    rserve_log_path: '/var/www/rails/openstudio/log/Rserve.log'
  }
)
