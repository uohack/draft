require 'sinatra/base'
require 'redis'
require 'connection_pool'
require 'json'
require 'omniauth'
require 'omniauth-twitter'
require 'active_support/all'

require 'dotenv'
Dotenv.load

if !ENV['REDISCLOUD_URL'].nil?
	redis_connection_string = ENV["REDISCLOUD_URL"] 
end

if ENV['REMOTE_REDIS'] == "true"
	redis_connection_string =`heroku config | grep REDIS`.split(":")[1..-1].join(":").strip #TODO: ugly
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
	configure do
		set :sessions, true
	end

	use OmniAuth::Builder do    
    	provider :twitter, ENV['TWITTER_CONSUMER_KEY'], ENV['TWITTER_CONSUMER_SECRET']
    end

	def get_id
		 REDIS.with{ |redis| redis.incr('next_id') }
	end

	def get_post(id)
		REDIS.with{ |redis| redis.get("post:#{id}") }
	end
	def record_pageview(id)
		REDIS.with{ |redis| 
			redis.incr("views_total") 
			redis.incr("post:#{id}:total")
		}
	end

	get '/' do
		erb :index
	end

	get '/logout' do
		session[:authenticated] = false
		session[:nickname] = nil
		redirect '/'
	end

	get '/auth/:provider/callback' do

    	nickname = request.env['omniauth.auth']['info']['nickname']    		
    	REDIS.with{ |redis|     		
    		redis.sadd('users', nickname)
    		redis.set("user:#{nickname}", JSON.generate(request.env['omniauth.auth']))
    	}
    	session[:authenticated] = true
    	session[:nickname] = nickname

    	if !session['pre_auth_path'].nil?
    		redirect session['pre_auth_path']
    		session['pre_auth_path'] = nil
    	else
    		puts JSON.generate(request.env['omniauth.auth'])
    		redirect '/'
    	end

  	end

  	get '/users' do
		erb :show_user_list, locals: { users: REDIS.with{ |redis| redis.smembers("users") } }
  	end

	get '/u/:user_id' do
		user = nil
		posts = nil
		REDIS.with{ |redis|  
			user = JSON.parse(redis.get("user:#{params['user_id']}"))
			posts = redis.smembers("user:#{params['user_id']}:posts").map{|post_id|
				post_id.to_s.split(":")[1]
			}
		}
		erb :show_user, locals: {user: user, posts: posts}
	end

	get '/favicon.ico' do
		nil
	end

	get '/timeline' do
		events = REDIS.with{ |redis|                         
			redis.zrangebyscore("timeline", "-inf", "+inf")
		}.map{|item|
			JSON.parse(item)
		}.reverse
		erb :timeline, locals: { events: events }
	end

	get '/:post_id' do
		content_type 'text/html'
		html = get_post(params['post_id'])
		if !html.nil?
			record_pageview(params['post_id'])
			return html
		else
			status 404
			erb :not_found
		end
	end

	get '/:post_id/edit' do
		if session[:authenticated] == true
			erb :edit_page, locals: {
				html: get_post(params['post_id']) || '',
				post_id: params['post_id']
			}
		else
			session['pre_auth_path'] = request.path	
			redirect '/auth/twitter' 
		end		
	end

	post '/:post_id' do
		throw(:halt, [401, "Not authorized. Please log in and try again.\n"]) unless session[:authenticated] == true and !session[:nickname].nil?

		REDIS.with{ |redis| 
			key = "post:#{params['post_id']}"
			redis.sadd("all_posts", key)
			redis.sadd("user:#{session['nickname']}:posts", key)			
			redis.set(key, params["html"]) 
			redis.zadd("timeline", Time.now.utc.to_i, JSON.generate({ time: Time.now.utc.to_i, nickname: session["nickname"], post_id: params["post_id"], html: params["html"] }))
		}
		redirect "/#{params['post_id']}"
	end

end
