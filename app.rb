require 'sinatra'
require 'json'
require_relative 'lib/efficiency_parser'

set :bind, '0.0.0.0'
set :public_folder, File.expand_path('public', __dir__)
set :views, File.expand_path('views', __dir__)
set :static, true
enable :static

get '/' do
  @asset_v = Time.now.to_i
  erb :index, locals: { asset_v: @asset_v }
end

get '/api/job-efficiency-summary' do
  content_type :json

  begin
    state_filter = params[:state_filter].to_s
    state_filter = 'total' if state_filter == 'terminal'
    state_filter = 'total' unless ['completed', 'total'].include?(state_filter)

    summary = EfficiencyParser.get_job_efficiency_summary(state_filter: state_filter)
    { success: true, data: summary }.to_json
  rescue => e
    status 500
    { success: false, error: e.message }.to_json
  end
end

get '/health' do
  content_type :json
  { status: 'ok', timestamp: Time.now.to_i }.to_json
end
