# -*- encoding : utf-8 -*-
require 'digest/sha1'

class User < ActiveRecord::Base
  #FIXME: THIS WHOLE MODEL SHOULD BE CALLED ACCOUNT

  # Virtual attribute for the unencrypted password
  attr_accessor :password, :name
  cattr_accessor :cache

  has_and_belongs_to_many :roles
  belongs_to :invite_sender, :class_name=>'Card', :foreign_key=>'invite_sender_id'
  has_many :invite_recipients, :class_name=>'Card', :foreign_key=>'invite_sender_id'

  validates_presence_of     :email, :if => :email_required?
  validates_format_of       :email, :with => /^([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})$/i  , :if => :email_required?
  validates_length_of       :email, :within => 3..100,   :if => :email_required?
  validates_uniqueness_of   :email, :scope=>:login,      :if => :email_required?
  validates_presence_of     :password,                   :if => :password_required?
  validates_presence_of     :password_confirmation,      :if => :password_required?
  validates_length_of       :password, :within => 5..40, :if => :password_required?
  validates_confirmation_of :password,                   :if => :password_required?
  validates_presence_of     :invite_sender,              :if => :active?
#  validates_uniqueness_of   :salt, :allow_nil => true

  before_validation :downcase_email!
  before_save :encrypt_password
  after_save :reset_instance_cache

  class << self
    def admin()          User.where(:card_id=>Card::WagnBotID).first  end
    def as_user()        User.where(:card_id=>Session.as_id).first end
    def user()           User.where(:card_id=>Session.user_id).first    end
    def from_id(card_id) User.where(:card_id=>card_id).first         end

    # FIXME: args=params.  should be less coupled..
    def create_with_card(user_args, card_args, email_args={})
      #warn  "create with(#{user_args.inspect}, #{card_args.inspect}, #{email_args.inspect})"
      card_args[:type_id] ||= Card::UserID
      @card = Card.fetch_or_new(card_args[:name], card_args)
      #warn "create with >>#{Session.user_card.name}"
      #warn "create with args= #{({:invite_sender=>Session.user_card, :status=>'active'}.merge(user_args)).inspect}"
      Session.as_bot do
        #warn "cwa #{user_args.inspect}, #{card_args.inspect}"
        @user = User.new({:invite_sender=>Session.user_card, :status=>'active'}.merge(user_args))
        #warn "user is #{@user.inspect}" unless @user.email
        @user.generate_password if @user.password.blank?
        @user.save_with_card(@card)
        @user.send_account_info(email_args) if @user.errors.empty? && !email_args.empty?
      end
      [@user, @card]
    end

    # Authenticates a user by their login name and unencrypted password.  Returns the user or nil.
    def authenticate(email, password)
      u = self.find_by_email(email.strip.downcase)
      u && u.authenticated?(password.strip) ? u : nil
    end

    # Encrypts some data with the salt.
    def encrypt(password, salt)
      Digest::SHA1.hexdigest("#{salt}--#{password}--")
    end

    # User caching, needs work
    def [](key)
      #warn (Rails.logger.info "Looking up USER[ #{key}]")

      key = 3 if key == :first
      @card = Card===key ? key : Card[key]
      key = case key
        when Integer; "##{key}"
        when Card   ; key.key
        when Symbol ; key.to_s
        when String ; key
        else raise "bad class for user key #{key.class}"
        end

      usr = self.cache.read(key)
      return usr if usr

      # cache it (on codename too if there is one)
      card_id ||= @card && @card.id
      self.cache.write(key, usr)
      code = Wagn::Codename[card_id].to_s and code != key and self.cache.write(code.to_s, usr)
      usr
    end
  end

#~~~~~~~ Instance

  def reset_instance_cache
    self.class.cache.write(id.to_s, nil)
    self.class.cache.write(login, nil) if login
  end

  def save_with_card(card)
    #warn(Rails.logger.info "save with card #{card.inspect}, #{self.inspect}")
    User.transaction do
      card = card.refresh if card.frozen?
      newcard = card.new_card?
      card.save
      #warn "save with_card #{User.count}, #{card.id}, #{card.inspect}"
      card.errors.each do |key,err|
        self.errors.add key,err
      end
      self.card_id = card.id
      save
      if newcard && errors.any?
        card.delete #won't the rollback take care of this?  if not, should Wagn Bot do it?
        self.card_id=nil
        save
        raise ActiveRecord::Rollback
      end
      true
    end
  rescue Exception => e
    warn (Rails.logger.info "save with card failed. #{e.inspect},  #{card.inspect} Bt:#{e.backtrace*"\n"}")
  end

  def accept(card, email_args)
    Session.as_bot do #what permissions does approver lack?  Should we check for them?
      card.type_id = Card::UserID # Invite Request -> User
      self.status='active'
      self.invite_sender = Session.user_card
      generate_password
      r=save_with_card(card)
    end
    #card.save #hack to make it so last editor is current user.
    self.send_account_info(email_args) if self.errors.empty?
  end

  def send_account_info(args)
    #return if args[:no_email]
    raise(Wagn::Oops, "subject is required") unless (args[:subject])
    raise(Wagn::Oops, "message is required") unless (args[:message])
    begin
      #warn "send_account_info(#{args.inspect})"
      message = Mailer.account_info(self, args[:subject], args[:message])
      message.deliver
    rescue Exception=>e
      warn Rails.logger.info("ACCOUNT INFO DELIVERY FAILED: \n #{args.inspect}\n   #{e.message}, #{e.backtrace*"\n"}")
    end
  end

  def anonymous?() card_id == Card::AnonID end

  def active?()   status=='active'  end
  def blocked?()  status=='blocked' end
  def built_in?() status=='system'  end
  def pending?()  status=='pending' end

  # blocked methods for legacy boolean status
  def blocked=(block)
    if block != '0'
      self.status = 'blocked'
    elsif !built_in?
      self.status = 'active'
    end
  end

  def authenticated?(password)
    crypted_password == encrypt(password) and active?
  end

  PW_CHARS = ['A'..'Z','a'..'z','0'..'9'].map(&:to_a).flatten

  def generate_password
    self.password_confirmation = self.password =
      9.times.map { PW_CHARS[rand*61] }*''
  end

  def to_s
    "#<#{self.class.name}:#{login.blank? ? email : login}}>"
  end

  def mocha_inspect
    to_s
  end

  #before validation
  def downcase_email!
    if e = self.email and e != e.downcase
      self.email=e.downcase
    end
  end 
   
  def card()
#    raise "deprecate user.card #{card_id}, #{@card&&@card.id} #{caller*"\n"}"
    @card && @card.id == card_id ? @card : @card = Card[card_id]
  end

  protected
  # Encrypts the password with the user salt
  def encrypt(password)
    self.class.encrypt(password, salt)
  end

  # before save
  def encrypt_password
    return if password.blank?
    self.salt = Digest::SHA1.hexdigest("--#{Time.now.to_s}--#{login}--") if new_record?
    self.crypted_password = encrypt(password)
  end

  def email_required?
    !built_in?
  end

  def password_required?
     !built_in? &&
     !pending?  &&
     #not_openid? &&
     (crypted_password.blank? or not password.blank?)
  end

end

