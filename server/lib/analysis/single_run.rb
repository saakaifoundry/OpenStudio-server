class Analysis::SingleRun
  include Analysis::Core

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
          number_of_samples: 1,
          sample_method: 'all_variables'
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

    Rails.logger.info "Initializing analysis for #{@analysis.name} with UUID of #{@analysis.uuid}"

    # make this a core method
    Rails.logger.info "Setting R base random seed to #{@analysis.problem['random_seed']}"

    selected_variables = Variable.pivots(@analysis.id) + Variable.variables(@analysis.id)
    Rails.logger.info "Found #{selected_variables.count} variables to perturb"

    # generate the probabilities for all variables as column vectors
    grouped = {}
    samples = {}
    var_types = []

    # get the probabilities
    Rails.logger.info "Found #{selected_variables.count} variables"

    i_var = 0
    selected_variables.each do |var|
      Rails.logger.info "sampling variable #{var.name} for measure #{var.measure.name}"
      variable_samples = nil
      # TODO: would be nice to have a field that said whether or not the variable is to be discrete or continuous.
      if var.uncertainty_type == 'discrete'
        variable_samples = var.static_value
        var_types << 'discrete'
      else
        variable_samples = var.static_value
        var_types << 'continuous'
      end

      # always add the data to the grouped hash even if it isn't used
      grouped["#{var.measure.id}"] = {} unless grouped.key?(var.measure.id)
      grouped["#{var.measure.id}"]["#{var.id}"] = variable_samples

      # save the samples to the
      samples["#{var.id}"] = variable_samples

      var.r_index = i_var + 1 # r_index is 1-based
      var.save!

      i_var += 1
    end

    Rails.logger.info "Samples are #{samples}"

    dp_name = 'Single Run Autogenerated'
    dp = @analysis.data_points.new(name: dp_name)
    dp.set_variable_values = samples
    dp.save!

    # This is here mainly for testing, but feel free to really use it.
    @analysis.results[@options[:analysis_type]] = { last_message: 'completed successfully' }
    @analysis.save!

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

  # Since this is a delayed job, if it crashes it will typically try multiple times.
  # Fix this to 1 retry for now.
  def max_attempts
    1
  end
end
