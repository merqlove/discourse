# frozen_string_literal: true

# https://meta.discourse.org/t/how-to-import-posts-in-csv-format/77107/3
# https://meta.discourse.org/t/importing-from-kunena-3/43776
# https://meta.discourse.org/t/beginners-guide-to-install-discourse-on-macos-for-development/15772
# https://meta.discourse.org/t/topic-and-category-export-import/38930

require "mysql2"
require "byebug"
require "net/http"
require "reverse_markdown"
require File.expand_path(File.dirname(__FILE__) + "/base.rb")

# If you change this script's functionality, please consider making a note here:
# https://meta.discourse.org/t/importing-from-kunena-3/43776

# Before running this script, paste these lines into your shell,
# then use arrow keys to edit the values
=begin
export DB_HOST="localhost"
export DB_NAME="kunena"
export DB_USER="kunena"
export DB_PW="kunena"
export KUNENA_PREFIX="jos_" # "iff_" sometimes
export IMAGE_PREFIX="http://EXAMPLE.com/media/kunena/attachments"
export PARENT_FIELD="parent_id" # "parent" in some versions
=end

class ImportScripts::Fireboard < ImportScripts::Base

  DB_HOST ||= ENV['DB_HOST'] || "127.0.0.1"
  DB_PORT ||= ENV['DB_PORT'] || "3306"
  DB_NAME ||= ENV['DB_NAME'] || "board"
  DB_USER ||= ENV['DB_USER'] || "root"
  DB_PW   ||= ENV['DB_PW'] || "board"
  KUNENA_PREFIX ||= ENV['KUNENA_PREFIX'] || "jos_" # "iff_" sometimes
  DOMAIN_PREFIX ||= ENV['DOMAIN_PREFIX'] || "http://p98513ev.beget.tech"
  FBFILES_PREFIX ||= ENV['FBFILES_PREFIX'] || "#{DOMAIN_PREFIX}/images/fbfiles"
  # FIREBOARD_PREFIX ||= ENV['AVATAR_PREFIX'] || "#{DOMAIN_PREFIX}/components/com_fireboard"
  # AVATAR_PREFIX ||= ENV['AVATAR_PREFIX'] || "#{FIREBOARD_PREFIX}/avatars"
  PARENT_FIELD ||= ENV['PARENT_FIELD'] || "parent" # "parent" in some versions
  CLEAN_ATTACHMENT_PATH ||= ENV['REPLACE_ATTACHMENT_PATH'] || "/storage/home/srv1435/183528.hoster-test.ru/html//" # "parent" in some versions
  CLEAN_ATTACHMENT_PATH2 ||= ENV['REPLACE_ATTACHMENT_PATH2'] || "/home/zlatover/public_html/" # "parent" in some versions
  CLEAN_ATTACHMENT_PATH3 ||= ENV['REPLACE_ATTACHMENT_PATH3'] || "/pub/home/zlatoverst/htdocs/" # "parent" in some versions
  CLEAN_ATTACHMENT_PATH4 ||= ENV['REPLACE_ATTACHMENT_PATH4'] || "/home/elftlru/public_html/zlatoverst/" # "parent" in some versions
  UPLOADS_PATH ||= ENV['UPLOADS_PATH'] || "tmp/uploads"
  FIREBOARD_PREFIX ||= ENV['AVATAR_PREFIX'] || "#{UPLOADS_PATH}/components/com_fireboard"
  AVATAR_PREFIX ||= ENV['AVATAR_PREFIX'] || "#{FIREBOARD_PREFIX}/avatars"
  BBCODE_MATCH = %r{(\[([^/].*?)(=(.+?))?\](.*?)\[/\2\]|\[([^/].*?)(=(.+?))?\])}

  def initialize

    super

    @users = {}

    @client = Mysql2::Client.new(
      host: DB_HOST,
      port: DB_PORT,
      username: DB_USER,
      password: DB_PW,
      database: DB_NAME
    )
  end

  def execute
    parse_users

    puts "creating users"

    create_users(@users.select { |_, v| v[:fb] }) do |id, user|
      { id: id,
        email: user[:email],
        username: user[:username],
        name: clean_up_text(user[:name]),
        # custom_fields: {
        #   user_option: {
        #     hide_profile_and_presence: user[:show_online],
        #   }
        # },
        created_at: user[:created_at],
        bio_raw: clean_up_text(user[:bio]),
        moderator: user[:moderator] ? true : false,
        admin: user[:admin] ? true : false,
        suspended_at: user[:suspended] || user[:block] ? Time.zone.now : nil,
        suspended_till: user[:suspended] || user[:block] ? 100.years.from_now : nil,
        post_create_action: proc do |new_user|
          if user[:suspended]
            :noop
          elsif user[:avatar_url].present?
            path = File.join(AVATAR_PREFIX, user[:avatar_url])
            if File.exists?(path)
              begin
                upload = create_upload(new_user.id, path, File.basename(path))
                if upload.persisted?
                  new_user.create_user_avatar
                  new_user.user_avatar.update(custom_upload_id: upload.id)
                  new_user.update(uploaded_avatar_id: upload.id)
                end
              rescue
                # don't care
              end
            end
          end
        end
      }
    end

    @users = nil

    create_categories(@client.query("SELECT id, parent, name, description, ordering FROM #{KUNENA_PREFIX}fb_categories ORDER BY parent, id;")) do |c|
      h = { id: c['id'], name: clean_up_text(c['name']), description: clean_up_text(c['description']), position: c['ordering'].to_i }
      if c['parent'].to_i > 0
        h[:parent_category_id] = category_id_from_imported_category_id(c['parent'])
      end
      h
    end

    import_posts

    begin
      create_admin(email: 'api@mrcr.ru', username: UserNameSuggester.suggest('Alex Merkulov'))
    rescue => e
      puts '', "Failed to create admin user"
      puts e.message
    end
  end

  def parse_users
    # Need to merge data from joomla with kunena

    puts "fetching Joomla users data from mysql"
    results = @client.query("SELECT id, name, username, email, usertype, block, registerDate FROM #{KUNENA_PREFIX}users;", cache_rows: false)
    results.each do |u|
      next unless u['id'].to_i > (0) && u['username'].present? && u['email'].present?
      username = u['username'].gsub(' ', '_').gsub(/[^A-Za-z0-9_]/, '')[0, User.username_length.end]
      username = UserNameSuggester.suggest(u['email']) if username.size < 3
      if username.length < User.username_length.first
        username = username * User.username_length.first
      end
      @users[u['id'].to_i] = { id: u['id'].to_i,
                               username: username,
                               name: u['name'],
                               email: u['email'],
                               block:  (u['block'].to_i == 1),
                               usertype: u['usertype'],
                               created_at: u['registerDate'] }
    end

    puts "fetching Kunena user data from mysql"
    results = @client.query("SELECT userid, showOnline, rank, birthdate, gender, avatar, signature, moderator, ban FROM #{KUNENA_PREFIX}fb_users;", cache_rows: false)
    results.each do |u|
      next unless u['userid'].to_i > 0
      user = @users[u['userid'].to_i]

      if user
        avatar_url = u['avatar'].present? ? u['avatar'] : nil
        @users[u['userid'].to_i] =
          update_user(u['userid'].to_i, {
            fb: true,
            show_online: (u['showOnline'].to_i == 1),
            bio: u['signature'],
            birthdate: u['birthdate'],
            gender: u['gender'],
            avatar_url: avatar_url,
            rank: u['rank'],
            moderator: (u['moderator'].to_i == 1),
            suspended: (u['ban'].to_i == 1)
          })
      end
    end
  end

  def import_posts
    puts '', "creating topics and posts"

    total_count = @client.query("SELECT COUNT(*) count FROM #{KUNENA_PREFIX}fb_messages m;").first['count']

    batch_size = 1000

    batches(batch_size) do |offset|
      results = @client.query("
        SELECT m.id id,
               m.thread thread,
               m.parent parent,
               m.catid catid,
               m.userid userid,
               m.subject subject,
               m.time time,
               t.message message
        FROM #{KUNENA_PREFIX}fb_messages m,
             #{KUNENA_PREFIX}fb_messages_text t
        WHERE m.id = t.mesid
        ORDER BY m.id
        LIMIT #{batch_size}
        OFFSET #{offset};
      ", cache_rows: false)

      break if results.size < 1

      next if all_records_exist? :posts, results.map { |p| p['id'].to_i }

      create_posts(results, total: total_count, offset: offset) do |m|
        skip = false
        mapped = {}

        mapped[:id] = m['id']
        mapped[:user_id] = user_id_from_imported_user_id(m['userid']) || -1

        id = m['userid']
        mapped[:raw] = clean_up_post(m["message"], m['id'], user_id_from_imported_user_id(m['userid']))
        mapped[:created_at] = Time.zone.at(m['time'])

        if m['parent'] == 0
          mapped[:category] = category_id_from_imported_category_id(m['catid'])
          mapped[:title] = clean_up_text(m['subject'])
        else
          parent = topic_lookup_from_imported_post_id(m['parent'])
          if parent
            mapped[:topic_id] = parent[:topic_id]
            mapped[:reply_to_post_number] = parent[:post_number] if parent[:post_number] > 1
          else
            puts "Parent post #{m['parent']} doesn't exist. Skipping #{m["id"]}: #{m["subject"][0..40]}"
            skip = true
          end
        end

        skip ? nil : mapped
      end
    end
  end

  def update_user(id, value)
    @users[id] = {} unless @users.has_key?(id)
    @users[id].merge(value)
  end

  def valid_url(url)
    check_url(url) ? url : nil
  end

  def check_url(url)
    return false unless url.present?
    url = URI.parse(url)
    user_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_7_0) AppleWebKit/535.2 (KHTML, like Gecko) Chrome/15.0.854.0 Safari/535.2"
    req = Net::HTTP.new(url.host, url.port)
    res = req.request_head(url.path, {'User-Agent' => user_agent})
    res.code == "200"
  end

  def clean_up_text(text)
    text&.encode("utf-8", "utf-8", invalid: :replace, undef: :replace, replace: "")
  end

  def clean_up_post(raw, post_id, user_id = -1)
    return raw if raw.blank?

    raw.encode!("utf-8", "utf-8", invalid: :replace, undef: :replace, replace: "")

    # doc = Nokogiri::HTML.fragment(raw)

    markdown = ReverseMarkdown.convert(raw)

    markdown.gsub!("[u]", "")
    markdown.gsub!("[/u]", "")

    markdown.gsub!("[quote]", "\n> ")
    markdown.gsub!("[/quote]", "\n")

    markdown.gsub!("[b]", "**")
    markdown.gsub!("[/b]", "**")

    markdown.gsub!("[i]", "*")
    markdown.gsub!("[/i]", "*")

    markdown.gsub!(BBCODE_MATCH) do
      data =
        if $1.present? && $2.present?
          if $2 == "url"
            if $4 == nil
              fix_url($5)
            else
              fix_url($4, $5)
            end
          elsif $2 == "quote"
            "> #{$5}"
          else
            if $5&.include?("zlatoverstmcc.ru")
              ""
            else
              $5
            end
          end
        else
          $1
        end
      data
    end

    markdown.gsub!(/http:\/\/zlatoverstmcc.ru\/index.php.*com_fireboard[&a-zA-Z0-9=#;]+/) do
      fix_url($1)
    end

    results = @client.query("SELECT filelocation FROM #{KUNENA_PREFIX}fb_attachments WHERE mesid = #{post_id}")
    uploads = results.map do |a|
      upload_file(a['filelocation'], user_id)
    end

    markdown = uploads.compact.reduce(markdown) do |acc, upload|
      <<MARKDOWN
#{acc}
#{upload}
MARKDOWN
    end

    markdown.gsub("\\", "")
  end

  def upload_file(file_location, user_id)
    file_path = file_location
                  &.sub(CLEAN_ATTACHMENT_PATH, '')
                  &.sub(CLEAN_ATTACHMENT_PATH2, '')
                  &.sub(CLEAN_ATTACHMENT_PATH3, '')
                  &.sub(CLEAN_ATTACHMENT_PATH4, '')
    file_name = File.basename(file_path)
    path = File.join(UPLOADS_PATH, file_path)
    dir_path = File.dirname(path)

    if File.exists?(path)
      begin
        upload = create_upload(user_id, path, file_name)
        return html_for_upload(upload, file_name) if upload&.persisted?
      rescue StandardError => e
        puts e.message
      end
    end
  end

  def fix_url(url, text = "Ссылка")
    return "[#{text || "Ссылка"}](#{url})" unless url.match?("zlatoverstmcc.ru")

    id = url.match(/id=([0-9]+)/)
    if id.size > 1
      "[#{text || "Ссылка"}](/t/demo/#{topic_lookup_from_imported_post_id(id[1].to_i) || id[1]})"
    end
  end
end

ImportScripts::Fireboard.new.perform
