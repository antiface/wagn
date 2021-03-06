# -*- encoding : utf-8 -*-

class Card < ActiveRecord::Base
  #Revision
  #Reference
  require 'card/revision'
  require 'card/reference'
end
class Card < ActiveRecord::Base

  cattr_accessor :cache

  has_many :revisions, :order => :id #, :foreign_key=>'card_id'

  attr_accessor :comment, :comment_author, :selected_rev_id,
    :confirm_rename, :confirm_destroy, :update_referencers, :allow_type_change, # seems like wrong mechanisms for this
    :cards, :loaded_trunk, :nested_edit, # should be possible to merge these concepts
    :error_view, :error_status, #yuck
    :attachment_id #should build flexible handling for set-specific attributes
      
  attr_writer :update_read_rule_list
  attr_reader :type_args, :broken_type
  
  belongs_to :card, :class_name => 'Card', :foreign_key => :creator_id
  belongs_to :card, :class_name => 'Card', :foreign_key => :updater_id

  before_save :set_stamper, :base_before_save, :set_read_rule, :set_tracked_attributes
  after_save :base_after_save, :update_ruled_cards, :update_queue, :expire_related
  
  cache_attributes 'name', 'type_id' #Review - still worth it in Rails 3?

  #~~~~~~  CLASS METHODS ~~~~~~~~~~~~~~~~~~~~~  

  class << self
    JUNK_INIT_ARGS = %w{ missing skip_virtual id }    

    def new args={}, options={}
      args = (args || {}).stringify_keys
      JUNK_INIT_ARGS.each { |a| args.delete(a) }
      %w{ type typecode }.each { |k| args.delete(k) if args[k].blank? }
      args.delete('content') if args['attach'] # should not be handled here!

      if name = args['name'] and !name.blank?
        if  Card.cache                                        and
            cc = Card.cache.read_local(name.to_cardname.key)  and
            cc.type_args                                      and
            args['type']          == cc.type_args[:type]      and
            args['typecode']      == cc.type_args[:typecode]  and
            args['type_id']       == cc.type_args[:type_id]   and
            args['loaded_trunk']  == cc.loaded_trunk

          args['type_id'] = cc.type_id
          return cc.send( :initialize, args )
        end
      end
      super args
    end
    
    ID_CONST_ALIAS = {
      :default_type => :basic,
      :anon         => :anonymous,
      :auth         => :anyone_signed_in,
      :admin        => :administrator
    }
    
    def const_missing const
      if const.to_s =~ /^([A-Z]\S*)ID$/ and code=$1.underscore.to_sym
        code = ID_CONST_ALIAS[code] || code
        if card_id = Wagn::Codename[code]
          const_set const, card_id
        else
          raise "Missing codename #{code} (#{const}) #{caller*"\n"}"
        end
      else
        Rails.logger.debug "need to load #{const.inspect}?"
        super
      end
    end
    
    def setting name
      Session.as_bot do
        card=Card[name] and !card.content.strip.empty? and card.content
      end
    end

    def path_setting name
      name ||= '/'
      return name if name =~ /^(http|mailto)/
      Wagn::Conf[:root_path] + name
    end

    def toggle val
      val == '1'
    end
  end


  # ~~~~~~ INSTANCE METHODS ~~~~~~~~~~~~~~~~~~~~~

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # INITIALIZATION

  def initialize args={}
    args['name']    = args['name'   ].to_s
    args['type_id'] = args['type_id'].to_i
    
    args.delete('type_id') if args['type_id'] == 0 # can come in as 0, '', or nil
    
    @type_args = { # these are cached to optimize #new
      :type     => args.delete('type'    ),
      :typecode => args.delete('typecode'),
      :type_id  => args[       'type_id' ]
    }

    skip_modules = args.delete 'skip_modules'

    super args # ActiveRecord #initialize
    
    if tid = get_type_id(@type_args)
      self.type_id_without_tracking = tid
    end

    include_set_modules unless skip_modules
    self
  end

  def get_type_id args={}
    return if args[:type_id] # type_id was set explicitly.  no need to set again.

    type_id = case
      when args[:typecode] ;  code=args[:typecode] and (
                              Wagn::Codename[code] || (c=Card[code] and c.id))
      when args[:type]     ;  Card.fetch_id args[:type]
      else :noop
      end
    
    case type_id
    when :noop      ; 
    when false, nil ; @broken_type = args[:type] || args[:typecode]
    else            ; return type_id
    end
    
    if name && t=template
      reset_patterns #still necessary even with new template handling?
      t.type_id
    else
      # if we get here we have no *all+*default -- let's address that!
      DefaultTypeID  
    end
  end

  def include_set_modules
    unless @set_mods_loaded
      set_modules.each do |m|
        singleton_class.send :include, m
      end
      @set_mods_loaded=true
    end
    self
  end

  def reset_mods
    #does this really do anything if it doesn't reset @set_modules???  can we get rid of this?
    @set_mods_loaded=false
  end
  
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # STATES

  def new_card?
    new_record? || !!@from_trash
  end

  def known?
    real? || virtual?
  end
  
  def real?
    !new_card?
  end

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # SAVING

  def assign_attributes args={}, options={}
    if args and newtype = args.delete(:type) || args.delete('type')
      args[:type_id] = Card.fetch_id( newtype )
    end
    reset_patterns
    
    super args, options
  end

  def set_stamper
    self.updater_id = Session.user_id
    self.creator_id = self.updater_id if new_card?
  end

  before_validation :on => :create do 
    pull_from_trash if new_record?
    self.trash = !!trash
    true
  end
  
  after_validation do
    begin
      raise PermissionDenied.new(self) unless approved?
      expire_pieces if errors.any?
      true
    rescue Exception => e
      expire_pieces
      raise e
    end
  end
  
  def save
    super
  rescue Exception => e
    expire_pieces
    raise e
  end
  
  def save!
    super
  rescue Exception => e
    expire_pieces
    raise e
  end

  def base_before_save
    if self.respond_to?(:before_save) and self.before_save == false
      errors.add(:save, "could not prepare card for destruction") #fixme - screwy error handling!!  
      return false
    end
  end

  def base_after_save
    save_subcards
    @virtual    = false
    @from_trash = false
    Wagn::Hook.call :after_create, self if @was_new_card
    send_notifications
    true
  rescue Exception=>e
    expire_pieces
    @subcards.each{ |card| card.expire_pieces }
    Rails.logger.info "after save issue: #{e.message}"
    raise e
  end

  def save_subcards
    @subcards = []
    return unless cards
    cards.each_pair do |sub_name, opts|
      opts[:nested_edit] = self
      sub_name = sub_name.gsub('~plus~','+')
      absolute_name = cardname.to_absolute_name(sub_name)
      if card = Card[absolute_name]
        card = card.refresh if card.frozen?
        card.update_attributes opts
      elsif opts[:content].present? and opts[:content].strip.present?
        opts[:name] = absolute_name
        card = Card.create opts
      end
      @subcards << card if card
      if card and card.errors.any?
        card.errors.each do |field, err|
          self.errors.add card.name, err
        end
        raise ActiveRecord::Rollback, "broke save_subcards"
      end
    end
  end

  def pull_from_trash
    return unless key
    return unless trashed_card = Card.find_by_key_and_trash(key, true)
    #could optimize to use fetch if we add :include_trashed_cards or something.
    #likely low ROI, but would be nice to have interface to retrieve cards from trash...
    self.id = trashed_card.id
    @from_trash = self.confirm_rename = @trash_changed = true
    @new_record = false
  end

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # DESTROY
  
  def destroy
    run_callbacks( :destroy ) do
      deps = self.dependents # already called once.  reuse?
      @trash_changed = true
      self.update_attributes :trash => true
      deps.each do |dep|
        dep.confirm_destroy = true
        dep.destroy
      end
      true
    end
  end    

  before_destroy do
    errors.clear
    validate_destroy

    dependents.each do |dep|
      dep.send :validate_destroy
      if dep.errors[:destroy].any?
        errors.add(:destroy, "can't destroy dependent card #{dep.name}: #{dep.errors[:destroy]}")
      end
    end

    if errors.any?
      return false
    else
      self.before_destroy if respond_to? :before_destroy
    end
  end

  def destroy!
    # FIXME: do we want to overide confirmation by setting confirm_destroy=true here?
    self.confirm_destroy = true
    destroy or raise Wagn::Oops, "Destroy failed: #{errors.full_messages.join(',')}"
  end

  def validate_destroy    
    if !dependents.empty? && !confirm_destroy
      errors.add(:confirmation_required, "because #{name} has #{dependents.size} dependents")
    else
      if code=self.codename
        errors.add :destroy, "#{name} is is a system card. (#{code})\n  Deleting this card would mess up our revision records."
      end
      if type_id== Card::UserID && Card::Revision.find_by_creator_id( self.id )
        errors.add :destroy, "Edits have been made with #{name}'s user account.\n  Deleting this card would mess up our revision records."
      end
      if respond_to? :custom_validate_destroy
        self.custom_validate_destroy
      end
    end
    errors.empty?
  end

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # NAME / RELATED NAMES


  # FIXME: use delegations and include all cardname functions
  def simple?()     cardname.simple?              end
  def junction?()   cardname.junction?            end
  def css_name()    cardname.css_name             end

  def left()      Card.fetch cardname.left_name   end
  def right()     Card.fetch cardname.tag_name    end
    

  def dependents
    return [] if new_card?
    Session.as_bot do
      Card.search( :part=>name ).map do |c|
        [ c ] + c.dependents
      end.flatten
    end
  end

  def repair_key
    Session.as_bot do
      correct_key = cardname.to_key
      current_key = key
      return self if current_key==correct_key

      if key_blocker = Card.find_by_key_and_trash(correct_key, true)
        key_blocker.cardname = key_blocker.cardname + "*trash#{rand(4)}"
        key_blocker.save
      end

      saved =   ( self.key  = correct_key and self.save! )
      saved ||= ( self.cardname = current_key and self.save! )

      if saved
        self.dependents.each { |c| c.repair_key }
      else
        Rails.logger.debug "FAILED TO REPAIR BROKEN KEY: #{key}"
        self.name = "BROKEN KEY: #{name}"
      end
      self
    end
  rescue
    Rails.logger.info "BROKE ATTEMPTING TO REPAIR BROKEN KEY: #{key}"
    self
  end


  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # TYPE

  def type_card
    Card[ type_id.to_i ]
  end
  
  def typecode # FIXME - change to "type_code"
    Wagn::Codename[ type_id.to_i ]
  end

  def type_name
    return if type_id.nil?
    card = Card.fetch type_id, :skip_modules=>true, :skip_virtual=>true
    card and card.name
  end

  def type= type_name
    self.type_id = Card.fetch_id type_name
  end

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # CONTENT / REVISIONS

  def content
    if new_card?
      template ? template.content : ''
    else
      current_revision.content
    end
  end
  
  def raw_content
    hard_template ? template.content : content
  end

  def selected_rev_id
    @selected_rev_id or ( ( cr = current_revision ) ? cr.id : 0 )
  end

  def current_revision
    #return current_revision || Card::Revision.new
    if @cached_revision and @cached_revision.id==current_revision_id
    elsif ( Card::Revision.cache &&
       @cached_revision=Card::Revision.cache.read("#{cardname.css_name}-content") and
       @cached_revision.id==current_revision_id )
    else
      rev = current_revision_id ? Card::Revision.find(current_revision_id) : Card::Revision.new()
      @cached_revision = Card::Revision.cache ?
        Card::Revision.cache.write("#{cardname.css_name}-content", rev) : rev
    end
    @cached_revision
  end

  def previous_revision revision_id
    if revision_id
      rev_index = revisions.find_index do |rev|
        rev.id == revision_id
      end
      revisions[rev_index - 1] if rev_index.to_i != 0
    end
  end

  def revised_at
    (current_revision && current_revision.created_at) || Time.now
  end

  def author
    Card[ creator_id ]
  end

  def updater
    Card[ updater_id || Card::AnonID ]
  end

  def drafts
    revisions.find(:all, :conditions=>["id > ?", current_revision_id])
  end

  def save_draft( content )
    clear_drafts
    revisions.create :content=>content
  end

  protected
  
  def clear_drafts # yuck!
    connection.execute(%{delete from card_revisions where card_id=#{id} and id > #{current_revision_id} })
  end

  public

  #~~~~~~~~~~~~~~ USER-ISH methods ~~~~~~~~~~~~~~#
  # these should be done in a set module when we have the capacity to address the set of "cards with accounts"
  # in the meantime, they should probably be in a module.

  def among? authzed
    prties = parties
    authzed.each { |auth| return true if prties.member? auth }
    authzed.member? Card::AnyoneID
  end

  def parties
    @parties ||= (all_roles << self.id).flatten.reject(&:blank?)
  end

  def read_rules
    @read_rules ||= begin
      if id==Card::WagnBotID
        [] # avoids infinite loop
      else
        party_keys = ['in', Card::AnyoneID] + parties
        Session.as_bot do
          Card.search(:right=>{:codename=>'read'}, :refer_to=>{:id=>party_keys}, :return=>:id).map &:to_i
        end
      end
    end
  end

  def all_roles
    ids = Session.as_bot { trait_card(:roles).item_cards(:limit=>0).map(&:id) }
    @all_roles ||= (id==Card::AnonID ? [] : [Card::AuthID] + ids)
  end

  def to_user
    User.where( :card_id => id ).first
  end # should be obsolete soon.


  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # TRAIT METHODS

  def existing_trait_card tagcode
    Card.fetch cardname.trait_name(tagcode), :skip_modules=>true, :skip_virtual=>true
  end

  def trait_card tagcode
    Card.fetch_or_new cardname.trait_name(tagcode), :skip_virtual=>true
  end


  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # METHODS FOR OVERRIDE
  # pretty much all of these should be done differently -efm

  def post_render( content )     content  end  
  def clean_html?()                 true  end
  def collection?()                false  end
  def on_type_change()                    end
  def validate_type_change()        true  end
  def validate_content( content )         end


  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # MISCELLANEOUS

  def to_s
    "#<#{self.class.name}[#{type_id < 1 ? 'bogus': type_name}:#{type_id}]#{self.attributes['name']}>"
  end
  
  def inspect
    "#<#{self.class.name}" + "(#{object_id})" + "##{self.id}" +
    "[#{type_id < 1 ? 'bogus': type_name}:#{type_id}]" +
    "!#{self.name}!{n:#{new_card?}:v:#{virtual?}:I:#{@set_mods_loaded}} " + 
    "R:#{ @rule_cards.nil? ? 'nil' : @rule_cards.map{|k,v| "#{k} >> #{v.nil? ? 'nil' : v.name}"}*", "}>"
  end

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # INCLUDED MODULES

  include Wagn::Model

  after_save :after_save_hooks
  # moved this after Wagn::Model inclusions because aikido module needs to come after Paperclip triggers,
  # which are set up in attach model.  CLEAN THIS UP!!!

  def after_save_hooks # don't move unless you know what you're doing, see above.
    Wagn::Hook.call :after_save, self
  end

  # Because of the way it chains methods, 'tracks' needs to come after
  # all the basic method definitions, and validations have to come after
  # that because they depend on some of the tracking methods.
  tracks :name, :type_id, :content, :comment

  # this method piggybacks on the name tracking method and
  # must therefore be defined after the #tracks call

  def name_with_resets= newname
    newkey = newname.to_cardname.key
    if key != newkey
      self.key = newkey 
      reset_patterns_if_rule # reset the old name - should be handled in tracked_attributes!!
      reset_patterns
    end
    @cardname = nil if name != newname.to_s
    self.name_without_resets = newname.to_s
  end
  alias_method_chain :name=, :resets
  alias cardname= name=

  def cardname
    @cardname ||= name.to_cardname
  end
  
  def autoname name
    if Card.exists? name
      autoname name.next
    else
      name
    end
  end

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # VALIDATIONS



  protected

  validate do |rec|
    return true if @nested_edit
    return true unless Wagn::Conf[:recaptcha_on] && Card.toggle( rec.rule(:captcha) )
    c = Wagn::Conf[:controller]
    return true if (c.recaptcha_count += 1) > 1
    c.verify_recaptcha( :model=>rec ) || rec.error_status = 449
  end

  validates_each :name do |rec, attr, value|
    if rec.new_card? && value.blank?
      if autoname_card = rec.rule_card(:autoname)
        Session.as_bot do
          autoname_card = autoname_card.refresh if autoname_card.frozen?
          value = rec.name = rec.autoname( autoname_card.content )
          autoname_card.content = value  #fixme, should give placeholder on new, do next and save on create
          autoname_card.save!
        end
      end
    end

    cdname = value.to_cardname
    if cdname.blank?
      rec.errors.add :name, "can't be blank"
    elsif rec.updates.for?(:name)
      #Rails.logger.debug "valid name #{rec.name.inspect} New #{value.inspect}"

      unless cdname.valid?
        rec.errors.add :name,
          "may not contain any of the following characters: #{
          Wagn::Cardname::CARDNAME_BANNED_CHARACTERS}"
      end
      # this is to protect against using a plus card as a tag
      if cdname.junction? and rec.simple? and Session.as_bot { Card.count_by_wql :tag_id=>rec.id } > 0
        rec.errors.add :name, "#{value} in use as a tag"
      end

      # validate uniqueness of name
      condition_sql = "cards.key = ? and trash=?"
      condition_params = [ cdname.to_key, false ]
      unless rec.new_record?
        condition_sql << " AND cards.id <> ?"
        condition_params << rec.id
      end
      if c = Card.find(:first, :conditions=>[condition_sql, *condition_params])
        rec.errors.add :name, "must be unique-- A card named '#{c.name}' already exists"
      end

      # require confirmation for renaming multiple cards  
      # FIXME - none of this should happen in the model.
      if !rec.confirm_rename
        pass = true
        if !rec.dependents.empty?
          pass = false
          rec.errors.add :confirmation_required, "#{rec.name} has #{rec.dependents.size} dependents"
        end

        if rec.update_referencers.nil? and !rec.extended_referencers.empty?
          pass = false
          rec.errors.add :confirmation_required, "#{rec.name} has #{rec.extended_referencers.size} referencers"
        end

        if !pass
          rec.error_view = :edit
          rec.error_status = 200 #I like 401 better, but would need special processing
        end
      end
    end
  end

  validates_each :content do |rec, attr, value|
    if rec.new_card? && !rec.updates.for?(:content)
      value = rec.content = rec.content #this is not really a validation.  is the double rec.content meaningful?  tracked attributes issue?
    end

    if rec.updates.for? :content
      rec.reset_patterns_if_rule
      rec.send :validate_content, value
    end
  end

  validates_each :current_revision_id do |rec, attrib, value|
    if !rec.new_card? && rec.current_revision_id_changed? && value.to_i != rec.current_revision_id_was.to_i
      rec.current_revision_id = rec.current_revision_id_was
      rec.errors.add :conflict, "changes not based on latest revision"
      rec.error_view = :conflict
      rec.error_status = 409
    end
  end

  validates_each :type_id do |rec, attr, value|
    # validate on update
    #warn "validate type #{rec.inspect}, #{attr}, #{value}"
    if rec.updates.for?(:type_id) and !rec.new_card?
      if !rec.validate_type_change
        rec.errors.add :type, "of #{ rec.name } can't be changed; errors changing from #{ rec.type_name }"
      end
#      if c = Card.new(:name=>'*validation dummy', :type_id=>value, :content=>'') and !c.valid?
      if c = rec.dup and c.type_id_without_tracking = value and c.id = nil and !c.valid?
        rec.errors.add :type, "of #{ rec.name } can't be changed; errors creating new #{ value }: #{ c.errors.full_messages * ', ' }"
      end
    end

    # validate on update and create
    if rec.updates.for?(:type_id) or rec.new_record?
      # invalid type recorded on create
      if rec.broken_type
        rec.errors.add :type, "won't work.  There's no cardtype named '#{rec.broken_type}'"
      end      
      
      # invalid to change type when type is hard_templated
      if rt = rec.hard_template and !rt.type_template? and value!=rt.type_id and !rec.allow_type_change
        rec.errors.add :type, "can't be changed because #{rec.name} is hard templated to #{rt.type_name}"
      end        
    end
  end

  validates_each :key do |rec, attr, value|
    if value.empty?
      rec.errors.add :key, "cannot be blank"
    elsif value != rec.cardname.to_key
      rec.errors.add :key, "wrong key '#{value}' for name #{rec.name}"
    end
  end

  # these old_modules should be refactored out
  require_dependency 'flexmail.rb'
  require_dependency 'google_maps_addon.rb'
  require_dependency 'notification.rb'
end
