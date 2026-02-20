require 'open3'
require 'time'

module EfficiencyParser
  def self.run_command(cmd)
    stdout, stderr, status = Open3.capture3(cmd)
    unless status.success?
      STDERR.puts "[EfficiencyParser] Command failed (exit #{status.exitstatus}): #{cmd}"
      STDERR.puts "[EfficiencyParser] STDERR: #{stderr}" unless stderr.empty?
      return stdout
    end
    stdout
  rescue => e
    STDERR.puts "[EfficiencyParser] Exception executing command: #{e.message}"
    STDERR.puts "[EfficiencyParser] Command was: #{cmd}"
    ""
  end

  def self.get_job_efficiency_summary(state_filter: 'total')
    {
      state_filter: state_filter,
      last_7_days: get_job_efficiency_window(days: 7, state_filter: state_filter),
      last_30_days: get_job_efficiency_window(days: 30, state_filter: state_filter)
    }
  end

  private

  def self.get_job_efficiency_window(days:, state_filter: 'total')
    end_date = Time.now
    start_date = end_date - (days * 24 * 60 * 60)
    start_str = start_date.strftime('%Y-%m-%d')
    end_str = (end_date + 86400).strftime('%Y-%m-%d')

    output = run_command(
      "sacct --user=$USER --starttime #{start_str} --endtime #{end_str} " +
      "--format=JobID,State,ElapsedRaw,TimelimitRaw,NCPUS,NNodes,TotalCPU,MaxRSS,ReqMem,TRESUsageInMax,ReqTRES " +
      '--noheader --parsable2'
    )

    cpu_values = []
    mem_values = []
    runtime_values = []
    mem_used_bytes_values = []
    requested_cpu_values = []
    requested_gpu_values = []
    requested_mem_bytes_values = []
    requested_runtime_seconds_values = []

    jobs_considered = 0
    job_memory = {}
    main_job_rows = []

    output.each_line do |line|
      parts = line.strip.split('|', -1)
      next if parts.length < 11

      job_id = parts[0].to_s.strip
      next if job_id.empty?

      main_job_id = job_id.split('.').first
      max_rss_bytes = parse_memory_to_bytes(parts[7].to_s.gsub('+', ''))
      if max_rss_bytes <= 0
        max_rss_bytes = parse_tres_memory_to_bytes(parts[9])
      end
      if max_rss_bytes > 0 && (!job_memory[main_job_id] || max_rss_bytes > job_memory[main_job_id])
        job_memory[main_job_id] = max_rss_bytes
      end

      next if job_id.include?('.')
      main_job_rows << parts
    end

    main_job_rows.each do |parts|
      job_id = parts[0].to_s.strip
      state = parts[1].to_s.strip.upcase
      next if ['RUNNING', 'PENDING', 'CONFIGURING', 'COMPLETING'].include?(state)
      next unless include_state_for_efficiency?(state, state_filter)

      jobs_considered += 1
      elapsed_raw = parts[2].to_i
      timelimit_raw = parts[3].to_i
      cpus = parts[4].to_i
      nodes = parts[5].to_i
      total_cpu_seconds = parse_duration_to_seconds(parts[6])
      max_rss_bytes = job_memory[job_id] || parse_memory_to_bytes(parts[7].to_s.gsub('+', ''))
      if max_rss_bytes <= 0
        max_rss_bytes = parse_tres_memory_to_bytes(parts[9])
      end
      req_mem_bytes = parse_requested_memory_to_bytes(parts[8], cpus, nodes)
      req_gpus = parse_requested_gpus(parts[10])

      requested_cpu_values << cpus if cpus > 0
      requested_gpu_values << req_gpus if req_gpus && req_gpus >= 0
      requested_runtime_seconds_values << (timelimit_raw * 60) if timelimit_raw > 0
      requested_mem_bytes_values << req_mem_bytes if req_mem_bytes && req_mem_bytes > 0

      if elapsed_raw > 0
        cpu_alloc_seconds = elapsed_raw * [cpus, 1].max
        cpu_efficiency = percentage(total_cpu_seconds, cpu_alloc_seconds)
        cpu_values << cpu_efficiency if cpu_efficiency

        runtime_efficiency = percentage(elapsed_raw, timelimit_raw * 60)
        runtime_values << runtime_efficiency if runtime_efficiency
      end

      memory_efficiency = percentage(max_rss_bytes, req_mem_bytes)
      mem_values << memory_efficiency if memory_efficiency
      mem_used_bytes_values << max_rss_bytes if max_rss_bytes && max_rss_bytes > 0
    end

    {
      days: days,
      jobs_considered: jobs_considered,
      requested_cpu: summarize_range_metric(requested_cpu_values),
      requested_gpu: summarize_range_metric(requested_gpu_values),
      requested_memory: summarize_range_metric(requested_mem_bytes_values),
      requested_runtime: summarize_range_metric(requested_runtime_seconds_values),
      cpu: summarize_metric(cpu_values),
      memory: summarize_metric(mem_values, bytes_values: mem_used_bytes_values),
      runtime: summarize_metric(runtime_values)
    }
  end

  def self.include_state_for_efficiency?(state, state_filter)
    normalized = state.to_s.upcase
    return normalized == 'COMPLETED' if state_filter == 'completed'

    return false if ['RUNNING', 'PENDING', 'CONFIGURING', 'COMPLETING', 'SUSPENDED'].include?(normalized)

    terminal_states = %w[
      COMPLETED FAILED CANCELLED TIMEOUT OUT_OF_MEMORY PREEMPTED NODE_FAIL DEADLINE BOOT_FAIL
    ]
    return true if terminal_states.include?(normalized)

    true
  end

  def self.parse_memory_to_bytes(mem_str)
    return 0 if mem_str.nil? || mem_str.empty?

    clean = mem_str.to_s.strip.gsub('+', '')
    return 0 if clean.empty?

    if clean =~ /^([\d.]+)([KMGTPE]?)$/i
      value = Regexp.last_match(1).to_f
      unit = Regexp.last_match(2).upcase

      case unit
      when 'K' then (value * 1024).to_i
      when 'M' then (value * 1024 * 1024).to_i
      when 'G' then (value * 1024 * 1024 * 1024).to_i
      when 'T' then (value * 1024 * 1024 * 1024 * 1024).to_i
      when 'P' then (value * 1024 * 1024 * 1024 * 1024 * 1024).to_i
      when 'E' then (value * 1024 * 1024 * 1024 * 1024 * 1024 * 1024).to_i
      else value.to_i
      end
    else
      0
    end
  end

  def self.parse_duration_to_seconds(value)
    str = value.to_s.strip
    return 0 if str.empty?

    days = 0
    time_part = str
    if str.include?('-')
      day_str, time_part = str.split('-', 2)
      days = day_str.to_i
    end

    time_fields = time_part.split(':')
    return 0 if time_fields.length < 2 || time_fields.length > 3

    if time_fields.length == 3
      hours = time_fields[0].to_i
      minutes = time_fields[1].to_i
      seconds = time_fields[2].to_f
    else
      hours = 0
      minutes = time_fields[0].to_i
      seconds = time_fields[1].to_f
    end

    (days * 86_400) + (hours * 3600) + (minutes * 60) + seconds
  end

  def self.parse_requested_memory_to_bytes(req_mem, cpus, nodes)
    str = req_mem.to_s.strip
    return nil if str.empty?

    match = str.match(/^([\d.]+)([KMGTPE])([cn])?$/i)
    return nil unless match

    value = match[1].to_f
    unit = match[2].upcase
    mode = match[3]&.downcase

    multiplier = case unit
                 when 'K' then 1024
                 when 'M' then 1024**2
                 when 'G' then 1024**3
                 when 'T' then 1024**4
                 when 'P' then 1024**5
                 when 'E' then 1024**6
                 else 1
                 end

    base_bytes = (value * multiplier).to_i
    case mode
    when 'c' then base_bytes * [cpus, 1].max
    when 'n' then base_bytes * [nodes, 1].max
    else base_bytes
    end
  end

  def self.parse_requested_gpus(req_tres)
    tres = req_tres.to_s
    return 0 if tres.empty?
    return Regexp.last_match(1).to_i if tres =~ /gres\/gpu=(\d+)/
    return Regexp.last_match(1).to_i if tres =~ /gres\/gpu:[\w-]+:(\d+)/
    0
  end

  def self.parse_tres_memory_to_bytes(tres_value)
    str = tres_value.to_s.strip
    return 0 if str.empty?

    mem_token = str.split(',').find { |token| token.strip.start_with?('mem=') }
    return 0 unless mem_token

    raw = mem_token.split('=', 2)[1].to_s.strip
    parse_memory_to_bytes(raw)
  end

  def self.percentage(actual, requested)
    return nil if actual.nil? || requested.nil? || requested <= 0
    ((actual.to_f / requested.to_f) * 100.0).round(2)
  end

  def self.summarize_metric(values, bytes_values: nil)
    sorted = values.compact.sort
    count = sorted.length

    summary = {
      count: count,
      mean: count.positive? ? (sorted.sum / count.to_f).round(2) : nil,
      p50: percentile(sorted, 0.50),
      p90: percentile(sorted, 0.90),
      buckets: bucketize_efficiency(sorted)
    }

    if bytes_values
      clean_bytes = bytes_values.compact.select { |b| b > 0 }
      summary[:max_used_bytes] = clean_bytes.max
      summary[:avg_used_bytes] = clean_bytes.empty? ? nil : (clean_bytes.sum / clean_bytes.length.to_f).round
    end

    summary
  end

  def self.summarize_range_metric(values)
    sorted = values.compact.sort
    count = sorted.length
    return { count: 0, min: nil, median: nil, max: nil } if count.zero?

    mid = count / 2
    median = if count.odd?
               sorted[mid]
             else
               (sorted[mid - 1] + sorted[mid]) / 2.0
             end

    {
      count: count,
      min: sorted.first,
      median: median,
      max: sorted.last
    }
  end

  def self.percentile(sorted_values, ratio)
    return nil if sorted_values.empty?
    idx = ((sorted_values.length - 1) * ratio).round
    sorted_values[idx].round(2)
  end

  def self.bucketize_efficiency(values)
    buckets = {
      '0-25%' => 0,
      '25-50%' => 0,
      '50-75%' => 0,
      '75-100%' => 0
    }

    values.each do |v|
      if v < 25
        buckets['0-25%'] += 1
      elsif v < 50
        buckets['25-50%'] += 1
      elsif v < 75
        buckets['50-75%'] += 1
      else
        buckets['75-100%'] += 1
      end
    end

    buckets
  end
end
