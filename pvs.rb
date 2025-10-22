#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
Bundler.require(:default)

# rubocop:disable Layout/HashAlignment
# Mapping of new varserver variables to their types and purposes
# Based on doc/varserver-variables-public.csv
MEASURES = {
  # System-wide livedata
  '/sys/livedata/time'                => { type: 'to_i', kind: :timestamp },
  '/sys/livedata/pv_p'                => { type: 'to_f', kind: :metric },    # Production Power (kW)
  '/sys/livedata/pv_en'               => { type: 'to_f', kind: :metric },    # Production Energy (kWh)
  '/sys/livedata/net_p'               => { type: 'to_f', kind: :metric },    # Net Consumption Power (kW)
  '/sys/livedata/net_en'              => { type: 'to_f', kind: :metric },    # Net Consumption Energy (kWh)
  '/sys/livedata/site_load_p'         => { type: 'to_f', kind: :metric },    # Site Load Power (kW)
  '/sys/livedata/site_load_en'        => { type: 'to_f', kind: :metric },    # Site Load Energy (kWh)
  '/sys/livedata/ess_p'               => { type: 'to_f', kind: :metric },    # Battery Power (kW)
  '/sys/livedata/ess_en'              => { type: 'to_f', kind: :metric },    # Battery Energy (kWh)
  '/sys/livedata/soc'                 => { type: 'to_f', kind: :metric },    # Battery State of Charge (%)
  '/sys/livedata/backupTimeRemaining' => { type: 'to_i', kind: :metric },    # Battery Backup Time (minutes)

  # System info
  '/sys/info/serialnum'               => { type: 'to_s', kind: :property },
  '/sys/info/model'                   => { type: 'to_s', kind: :property },
  '/sys/info/sw_rev'                  => { type: 'to_s', kind: :property },
  '/sys/info/hwrev'                   => { type: 'to_s', kind: :property },

  # Inverter data fields (with {index} placeholder)
  'freqHz'                            => { type: 'to_f', kind: :metric },    # Frequency in Hz
  'iMppt1A'                           => { type: 'to_f', kind: :metric },    # DC Current (amperes)
  'ltea3phsumKwh'                     => { type: 'to_f', kind: :metric },    # Lifetime energy (kWh)
  'pMppt1Kw'                          => { type: 'to_f', kind: :metric },    # DC Power (kW)
  'p3phsumKw'                         => { type: 'to_f', kind: :metric },    # AC Power (kW)
  'tHtsnkDegc'                        => { type: 'to_f', kind: :metric },    # Heatsink temperature (°C)
  'vMppt1V'                           => { type: 'to_f', kind: :metric },    # DC Voltage (volts)
  'vln3phavgV'                        => { type: 'to_f', kind: :metric },    # AC Voltage (volts)
  'prodMdlNm'                         => { type: 'to_s', kind: :property },  # Model name
  'sn'                                => { type: 'to_s', kind: :property },  # Serial number
  'msmtEps'                           => { type: 'to_s', kind: :timestamp }, # Measurement timestamp

  # Meter data fields
  'ctSclFctr'                         => { type: 'to_i', kind: :metric },    # CT scaling factor
  'i1A'                               => { type: 'to_f', kind: :metric },    # Phase 1 current (A)
  'i2A'                               => { type: 'to_f', kind: :metric },    # Phase 2 current (A)
  'netLtea3phsumKwh'                  => { type: 'to_f', kind: :metric },    # Net lifetime energy (kWh)
  'posLtea3phsumKwh'                  => { type: 'to_f', kind: :metric },    # Positive lifetime energy (kWh)
  'negLtea3phsumKwh'                  => { type: 'to_f', kind: :metric },    # Negative lifetime energy (kWh)
  'p1Kw'                              => { type: 'to_f', kind: :metric },    # Phase 1 power (kW)
  'p2Kw'                              => { type: 'to_f', kind: :metric },    # Phase 2 power (kW)
  'q3phsumKvar'                       => { type: 'to_f', kind: :metric },    # Reactive power (kVAR)
  's3phsumKva'                        => { type: 'to_f', kind: :metric },    # Apparent power (kVA)
  'totPfRto'                          => { type: 'to_f', kind: :metric },    # Power factor ratio
  'v12V'                              => { type: 'to_f', kind: :metric },    # Phase 1-2 voltage (V)
  'v1nV'                              => { type: 'to_f', kind: :metric },    # Phase 1-neutral voltage (V)
  'v2nV'                              => { type: 'to_f', kind: :metric }     # Phase 2-neutral voltage (V)
}.freeze
# rubocop:enable Layout/HashAlignment

class Pvs < RecorderBotBase
  no_commands do
    def authenticate
      # Load credentials - expecting :pvs_serial_last5: in the YAML file
      credentials = load_credentials
      password = credentials[:pvs_serial_last5] || credentials['pvs_serial_last5']

      if password.nil? || password.empty?
        @logger.error 'Missing PVS serial last 5 digits in credentials'
        raise 'Authentication credentials not properly configured'
      end

      # Create auth header
      auth_string = Base64.strict_encode64("ssm_owner:#{password}")

      # Create temporary cookie file
      cookie_file = Tempfile.new(['pvs_cookies', '.txt'])

      # Authenticate and get session cookie
      auth_response = with_rescue([Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
                                   RestClient::Exceptions::OpenTimeout,
                                   RestClient::ServiceUnavailable, SocketError], @logger) do |_try|
        RestClient::Request.execute(
          method: :get,
          url: 'https://pvs-gateway.local/auth?login',
          headers: {
            'Authorization' => "Basic #{auth_string}"
          },
          cookies: {},
          verify_ssl: false
        )
      end

      # Extract session cookie from response
      session_cookie = auth_response.cookies['session']

      if session_cookie.nil?
        @logger.error 'Failed to obtain session cookie'
        raise 'Authentication failed'
      end

      # Store cookie in tempfile for subsequent requests
      cookie_file.write("# Netscape HTTP Cookie File\n")
      cookie_file.write("pvs-gateway.local\tFALSE\t/\tTRUE\t0\tsession\t#{session_cookie}\n")
      cookie_file.flush

      @logger.info 'Successfully authenticated with PVS'
      cookie_file
    end

    def fetch_varserver_data(cookie_file, query_params)
      # Read session cookie from file
      cookie_file.rewind
      session_cookie = nil
      cookie_file.each_line do |line|
        next if line.start_with?('#')

        parts = line.strip.split("\t")
        session_cookie = parts.last if parts[-2] == 'session'
      end

      url = "https://pvs-gateway.local/vars?#{query_params}"

      response = with_rescue([Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
                              RestClient::Exceptions::OpenTimeout,
                              RestClient::ServiceUnavailable, SocketError], @logger) do |_try|
        RestClient::Request.execute(
          method: :get,
          url: url,
          cookies: { session: session_cookie },
          verify_ssl: false
        )
      end

      JSON.parse(response.body)
    end

    def data_as_obj(data)
      device_data = Hash.new { |h, k| h[k] = {} }

      regex = %r{\A/sys/devices/(?<device_type>[^/]+)/(?<idx>\d+)/(?<metric>[^/]+)\z}

      data['values'].each do |entry|
        name  = entry['name']
        value = entry['value']

        m = regex.match(name) or next # skip this entry unless it matches

        out_key = "/sys/devices/#{m[:idx]}/#{m[:device_type]}/data"
        device_data[out_key][m[:metric]] = value
      end

      device_data
    end

    def record_values(values, timestamp, tags, influxdb)
      data = []
      values.each do |key, value|
        measure = MEASURES[key]
        next unless measure && measure[:kind] == :metric

        metric_name = key.split('/').last
        data.push({
                    series: metric_name,
                    values: { value: value.send(MEASURES[key][:type]) },
                    tags: tags,
                    timestamp: timestamp
                  })
      end

      influxdb.write_points(data) unless options[:dry_run]
    end

    def process_system_data(system_data, influxdb)
      # Process system-wide livedata
      return if system_data.nil? || system_data.empty?

      system_values = system_data['values'].each_with_object({}) do |entry, hash|
        hash[entry['name']] = entry['value']
      end
      timestamp = system_values['/sys/livedata/time'].to_i

      tags = { device_type: 'system' }
      record_values(system_values, timestamp, tags, influxdb)
    end

    def process_device_data(device_data, device_type, influxdb)
      return if device_data.nil? || device_data.empty?

      device_data.each do |device_path, device_values|
        next unless device_values.is_a?(Hash)

        # (e.g., /sys/devices/11/inverter/data)
        %r{/sys/devices/(\d+)/([^/]+)/data} =~ device_path
        device_index = Regexp.last_match(1)
        device_type  = Regexp.last_match(2)
        next unless device_index

        data = []
        tags = {
          device_type: device_type,
          device_index: format('%02d', device_index)
        }
        # Add device properties as tags
        tags[:serial] = device_values['sn'] if device_values['sn']
        tags[:model] = device_values['prodMdlNm'] if device_values['prodMdlNm']

        # Parse timestamp if available
        timestamp = nil
        if device_values['msmtEps']
          begin
            timestamp = DateTime.parse(device_values['msmtEps']).to_time.to_i
          rescue StandardError => e
            @logger.warn "Failed to parse timestamp: #{e.message}"
          end
        end

        record_values(device_values, timestamp, tags, influxdb)

        # Process metrics
        device_values.each do |key, value|
          measure = MEASURES[key]
          next unless measure && measure[:kind] == :metric

          begin
            metric_value = value.send(measure[:type])
            data.push({
                        series: key,
                        values: { value: metric_value },
                        tags: tags,
                        timestamp: timestamp
                      })
          rescue StandardError => e
            @logger.warn "Failed to process #{key}: #{e.message}"
          end
        end

        pp data if @logger.level == Logger::DEBUG
        influxdb.write_points(data) unless options[:dry_run] || data.empty?
      end
    end

    def main
      session = authenticate

      # Fetch data using new API with caching for efficiency
      livedata = fetch_varserver_data(session, 'match=livedata')
      @logger.debug "Livedata: #{livedata}"

      meter_data = data_as_obj(fetch_varserver_data(session, 'match=/sys/devices/meter/'))
      @logger.debug "Meter data: #{meter_data}"

      inverter_data = data_as_obj(fetch_varserver_data(session, 'match=/sys/devices/inverter/'))
      @logger.debug "Inverter data: #{inverter_data}"

      influxdb = options[:dry_run] ? nil : (InfluxDB::Client.new 'pvs')

      process_system_data(livedata, influxdb)

      # Process meter data
      process_device_data(meter_data, 'meter', influxdb)

      # Process inverter data
      process_device_data(inverter_data, 'inverter', influxdb)

      @logger.info 'Data collection complete'
    ensure
      session&.close if session.is_a?(Tempfile)
    end
  end
end

Pvs.start
