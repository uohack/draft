require 'sinatra/base'
require 'redis'
require 'connection_pool'
require 'json'

if !ENV['REDISCLOUD_URL'].nil?
	redis_connection_string = ENV["REDISCLOUD_URL"] 
end

if ENV['REMOTE_REDIS'] == "true"
	redis_connection_string =`heroku config | grep REDIS`.split(":")[1..-1].join(":").strip
end

REDIS = ConnectionPool.new(size: 5, timeout: 5) do
        if !redis_connection_string.nil?
        		puts "connecting to #{redis_connection_string}"
                uri = URI.parse(redis_connection_string)
                Redis.new(host: uri.host, port: uri.port, password: uri.password)
        else
        		puts "connecting to local redis"
                Redis.new
        end
end


class App < Sinatra::Base

	def get_id
		 REDIS.with{ |redis| redis.incr('next_id') }
	end

	def get_post(id)
		REDIS.with{ |redis| redis.get("post:#{id}") }
	end

	get '/' do
		erb :index
	end

	get '/u/:user_id' do
		erb :show_user
	end

	get '/favicon.ico' do
		''
	end

	get '/:post_id' do
		content_type 'text/html'
		html = get_post(params['post_id'])
		if !html.nil?
			return html
		else
			status 404
			erb :not_found
		end
	end

	get '/:post_id/edit' do
		erb :edit_page, locals: {
			html: get_post(params['post_id']) || 'nothing yet!',
			post_id: params['post_id']
		}
	end

	post '/:page_id' do
		REDIS.with{ |redis| redis.set("post:#{params['page_id']}", params['html']) }
		redirect "/#{params['page_id']}"
	end

end
