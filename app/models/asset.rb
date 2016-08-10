class Asset < ActiveRecord::Base
  include SearchableModel
  include DatabaseHelper
  include Encryptor
  include WopiUtil

  require 'tempfile'
  # Lock duration set to 30 minutes
  LOCK_DURATION = 60*30

  # Paperclip validation
  has_attached_file :file, {
    styles: {
      medium: '300x300>'
    }
  }

  validates_attachment :file, presence: true, size: { less_than: FILE_SIZE_LIMIT.megabytes }
  validates :estimated_size, presence: true
  validates :file_present, inclusion: { in: [true, false] }

  # Should be checked for any security leaks
  do_not_validate_attachment_file_type :file

  before_file_post_process :allow_styles_on_images

  # Asset validation
  # This could cause some problems if you create empty asset and want to
  # assign it to result
  validate :step_or_result

  belongs_to :created_by, foreign_key: 'created_by_id', class_name: 'User'
  belongs_to :last_modified_by, foreign_key: 'last_modified_by_id', class_name: 'User'
  has_one :step_asset,
    inverse_of: :asset,
    dependent: :destroy
  has_one :step, through: :step_asset,
    dependent: :nullify

  has_one :result_asset,
    inverse_of: :asset,
    dependent: :destroy
  has_one :result, through: :result_asset,
    dependent: :nullify
  has_many :report_elements, inverse_of: :asset, dependent: :destroy
  has_one :asset_text_datum, inverse_of: :asset, dependent: :destroy

  attr_accessor :file_content, :file_info, :preview_cached

  def file_empty(name, size)
    file_ext = name.split(".").last
    self.file_file_name = name
    self.file_content_type = Rack::Mime.mime_type(".#{file_ext}")
    self.file_file_size = size
    self.file_updated_at = DateTime.now
    self.file_present = false
  end

  def self.new_empty(name, size)
    asset = self.new
    asset.file_empty name, size
    asset
  end

  def self.search(
    user,
    include_archived,
    query = nil,
    page = 1
  )
    step_ids =
      Step
      .search(user, include_archived, nil, SHOW_ALL_RESULTS)
      .joins(:step_assets)
      .select("step_assets.id")
      .distinct

    result_ids =
      Result
      .search(user, include_archived, nil, SHOW_ALL_RESULTS)
      .joins(:result_asset)
      .select("result_assets.id")
      .distinct

    if query
      a_query = query.strip
      .gsub("_","\\_")
      .gsub("%","\\%")
      .split(/\s+/)
      .map {|t|  "%" + t + "%" }
    else
      a_query = query
    end

    # Trim whitespace and replace it with OR character. Make prefixed
    # wildcard search term and escape special characters.
    # For example, search term 'demo project' is transformed to
    # 'demo:*|project:*' which makes word inclusive search with postfix
    # wildcard.

    s_query = query.gsub(/[!()&|:]/, " ")
      .strip
      .split(/\s+/)
      .map {|t| t + ":*" }
      .join("|")
      .gsub('\'', '"')

    ids = Asset
      .select(:id)
      .distinct
      .joins("LEFT OUTER JOIN step_assets ON step_assets.asset_id = assets.id")
      .joins("LEFT OUTER JOIN result_assets ON result_assets.asset_id = assets.id")
      .joins("LEFT JOIN asset_text_data ON assets.id = asset_text_data.asset_id")
      .where("(step_assets.id IN (?) OR result_assets.id IN (?))", step_ids, result_ids)
      .where(
        "(assets.file_file_name ILIKE ANY (array[?]) " +
        "OR asset_text_data.data_vector @@ to_tsquery(?))",
        a_query,
        s_query
      )

    # Show all results if needed
    if page != SHOW_ALL_RESULTS
      ids = ids
        .limit(SEARCH_LIMIT)
        .offset((page - 1) * SEARCH_LIMIT)
    end

    Asset
      .joins("LEFT JOIN asset_text_data ON assets.id = asset_text_data.asset_id")
      .select("assets.*")
      .select("ts_headline(data, to_tsquery('" + s_query + "'),
        'StartSel=<mark>, StopSel=</mark>') headline")
      .where("assets.id IN (?)",  ids)
  end

  def is_image?
    !(self.file.content_type =~ /^image/).nil?
  end

  # TODO: get the current_user
  # before_save do
  #   if current_user
  #     self.created_by ||= current_user
  #     self.last_modified_by = current_user if self.changed?
  #   end
  # end

  def is_stored_on_s3?
    file.options[:storage].to_sym == :s3
  end

  def post_process_file(org = nil)
    # Update self.empty
    self.update(file_present: true)

    # Extract asset text if it's of correct type
    if TEXT_EXTRACT_FILE_TYPES.any? { |v| file_content_type.start_with? v }
      Rails.logger.info "Asset #{id}: Creating extract text job"
      # The extract_asset_text also includes
      # estimated size calculation
      delay(queue: :assets).extract_asset_text(org)
    else
      # Update asset's estimated size immediately
      update_estimated_size(org)
    end
  end

  def extract_asset_text(org = nil)
    if file.blank?
      return
    end

    begin
      file_path = file.path

      if file.is_stored_on_s3?
        fa = file.fetch
        file_path = fa.path
      end

      if (!Yomu.class_eval('@@server_pid'))
        Yomu.server(:text,nil)
        sleep(5)
      end
      y = Yomu.new file_path

      text_data = y.text

      if asset_text_datum.present?
        # Update existing text datum if it exists
        asset_text_datum.update(data: text_data)
      else
        # Create new text datum
        AssetTextDatum.create(data: text_data, asset: self)
      end

      Rails.logger.info "Asset #{id}: Asset file successfully extracted"

      # Finally, update asset's estimated size to include
      # the data vector
      update_estimated_size(org)
    rescue Exception => e
      Rails.logger.fatal "Asset #{id}: Error extracting contents from asset file #{file.path}: " + e.message
    ensure
      File.delete file_path if fa
    end
  end

  # If organization is provided, its space_taken
  # is updated as well
  def update_estimated_size(org = nil)
    if file_file_size.blank?
      return
    end

    es = file_file_size
    if asset_text_datum.present? and asset_text_datum.persisted? then
      asset_text_datum.reload
      es += get_octet_length_record(asset_text_datum, :data)
      es += get_octet_length_record(asset_text_datum, :data_vector)
    end
    es = es * ASSET_ESTIMATED_SIZE_FACTOR
    update(estimated_size: es)
    Rails.logger.info "Asset #{id}: Estimated size successfully calculated"

    # Finally, update organization's space
    if org.present?
      org.take_space(es)
      org.save
    end
  end

  def presigned_url
    if file.is_stored_on_s3?
      signer = Aws::S3::Presigner.new(client: S3_BUCKET.client)

      signer.presigned_url(:get_object,
        bucket: S3_BUCKET.name,
        key: file.path[1..-1],
        expires_in: 30,
        # this response header forces object download
        response_content_disposition: 'attachment; filename=' + file_file_name)
    end
  end

  # Preserving attachments (on client-side) between failed validations (only usable for small/few files!)
  # Needs to be called before save method and view needs to have :file_content and :file_info hidden field
  # If file is an image, it can be viewed on front-end using @preview_cached with image_tag tag
  def preserve(file_data)
    if file_data[:file_content].present?
      restore_cached(file_data[:file_content], file_data[:file_info])
    end
    cache
  end

  def can_perform_action(action)
    file_ext = file_file_name.split(".").last
    action = get_action(file_ext,action)
    if action.nil?
      return false
    end
    true
  end


  def get_action_url(user,action,with_tokens = true)
    file_ext = file_file_name.split(".").last
    action = get_action(file_ext,action)
    if !action.nil?
      action_url = action.urlsrc
      action_url = action_url.gsub(/<IsLicensedUser=BUSINESS_USER&>/, "IsLicensedUser=0&")
      action_url = action_url.gsub(/<IsLicensedUser=BUSINESS_USER>/, "IsLicensedUser=0")
      action_url = action_url.gsub(/<.*?=.*?>/, "")

      rest_url = Rails.application.routes.url_helpers.wopi_rest_endpoint_url(host: ENV["WOPI_ENDPOINT_URL"],id: id)
      action_url = action_url + "WOPISrc=#{rest_url}"
      if with_tokens
        action_url = action_url + "&access_token=#{user.get_wopi_token}&access_token_ttl=#{(user.wopi_token_ttl*1000).to_s}"
      else
        action_url
      end
    else
      return nil
    end
  end

  #is_locked, lock_asset and refresh_lock rely on the asset being locked in the database to prevent race conditions
  def is_locked
    if lock.nil?
      return false
    else
      return true
    end
  end

  def lock_asset(lock_string)
    self.lock = lock_string
    self.lock_ttl = Time.now.to_i + LOCK_DURATION
    delay(queue: :assets, run_at: LOCK_DURATION.seconds.from_now).unlock_expired
    self.save!
  end

  def refresh_lock
    self.lock_ttl = Time.now.to_i + LOCK_DURATION
    delay(queue: :assets, run_at: LOCK_DURATION.seconds.from_now).unlock_expired
    self.save!
  end

  def unlock
    self.lock = nil
    self.lock_ttl = nil
    self.save!
  end

  def unlock_expired
    self.with_lock do
      if !self.lock_ttl.nil? and self.lock_ttl>= Time.now.to_i
        self.lock = nil
        self.lock_ttl = nil
        self.save!
      end
    end
  end

  def update_contents(new_file)
    new_file.class.class_eval { attr_accessor :original_filename }
    new_file.original_filename = self.file_file_name
    self.file = new_file
    if self.version.nil?
      self.version = 1
    else
      self.version = self.version + 1
    end
      self.save
  end


  protected

  # Checks if attachments is an image (in post processing imagemagick will
  # generate styles)
  def allow_styles_on_images
    if !(file.content_type =~ %r{^(image|(x-)?application)/(x-png|pjpeg|jpeg|jpg|png|gif)$})
      return false
    end
  end

  private

  def file_changed?
    previous_changes.present? and
    (
      (
        previous_changes.key? "file_file_name" and
        previous_changes["file_file_name"].first !=
          previous_changes["file_file_name"].last
      ) or (
        previous_changes.key? "file_file_size" and
        previous_changes["file_file_size"].first !=
          previous_changes["file_file_size"].last
      )
    )
  end

  def step_or_result
    # We must allow both step and result to be blank because of GUI
    # (eventhough it's not really a "valid" asset)
    if step.present? && result.present?
      errors.add(:base, "Asset can only be result or step, not both.")
    end
  end

  def cache
    fetched_file = file.fetch
    file_content = fetched_file.read
    @file_content = encrypt(file_content)
    @file_info = %Q[{"content_type" : "#{file.content_type}", "original_filename" : "#{file.original_filename}"}]
    @file_info = encrypt(@file_info)
    if !(file.content_type =~ /^image/).nil?
      @preview_cached = "data:image/png;base64," + Base64.encode64(file_content)
    end
  end

  def restore_cached(file_content, file_info)
    decoded_data = decrypt(file_content)
    decoded_data_info = decrypt(file_info)
    decoded_data_info = JSON.parse decoded_data_info

    data = StringIO.new(decoded_data)
    data.class_eval do
      attr_accessor :content_type, :original_filename
    end
    data.content_type = decoded_data_info['content_type']
    data.original_filename = File.basename(decoded_data_info['original_filename'])

    self.file = data
  end

end
