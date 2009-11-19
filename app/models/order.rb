class Order < ActiveRecord::Base
  has_many :line_items
  belongs_to :coupon

  attr_accessor :cc_code, :cc_month, :cc_year
  attr_accessor :skip_cc_validation
  attr_accessor :email_receipt_when_finishing
  attr_writer :promo_coupons

  attr_protected :status, :skip_cc_validation

  validates_presence_of :payment_type

  def initialize(attributes = {}, form_items = [])
    attributes = attributes.clone()
    if attributes[:items]
      form_items = attributes[:items]
      attributes.delete(:items)
    end
    super(attributes)
    if form_items.length > 0
      self.add_form_items(form_items)
    end
    self.order_time = Time.now()
  end

  def validate
    ## Validate credit card order
    if self.cc_order? && !skip_cc_validation
      errors.add_on_blank(['first_name', 'last_name', 'address1', 'city', 'country', 'email'])
      if self.pending? or self.submitting?
        errors.add_on_blank(['cc_number', 'cc_month', 'cc_year', 'cc_code'])
      end

      if ['US', 'CA', 'JP'].member?(self.country)
        errors.add_on_blank('zipcode')
      end

      if ['US', 'CA'].member?(self.country)
        errors.add('state', msg = 'must be a 2 character abbreviation for USA and Canada') if self.state.size != 2
      end
    end

    ## Validate PayPal order
    if self.paypal_order?
      if self.submitting? or self.complete?
        errors.add_on_blank(['email'])
      end
    end

    ## If licensee name is all alpha-numeric, require it to be at least 8 characters.
    if self.submitting? or self.complete?
      if self.licensee_name == nil || self.licensee_name.strip == ''
        errors.add_on_blank(['licensee_name'])
      elsif (self.licensee_name =~ /^[\w ]*$/) != nil && self.licensee_name.length < 8
        errors.add('licensee_name', msg= 'must be at least 8 characters long')
      end
    end
  end

  def before_create
    if self.order_number == nil || self.order_number.empty?
      self.order_number = self.generate_order_number()
    end
  end

  def total
    return round_money(total_before_applying_coupons() - coupon_amount())
  end

  def total_before_applying_coupons
    total = 0
    for item in self.line_items
        total = total + item.total
    end
    return round_money(total)
  end

  ## tax and shipping are hard-wired to 0 for now
  def tax_total
    return 0
  end

  def shipping_total
    return 0
  end

  def coupon_amount
    return 0 if coupon == nil
    return coupon.amount if coupon.percentage == nil
    for item in self.line_items
      if coupon && coupon.percentage != nil && coupon.product_code == item.product.code
        return round_money(item.total * coupon.percentage / 100.0)
      end
    end
    if coupon && coupon.percentage != nil && coupon.product_code == 'all'
      return round_money(total_before_applying_coupons() * (coupon.percentage / 100.0))
    end
    return 0
  end

  def volume_discount_total
    total = self.total()
    self.line_items.collect{|x| x.regular_price * x.quantity}.each {|x| total -= x}
    return -total
  end

  def items_count
    return self.line_items.reject{|x| x.quantity <= 0}.length
  end

  def product_quantity(product_code)
    for item in self.line_items
      return item.quantity if item.product.code == product_code
    end
    return 0
  end

  def licensee_name=(new_name)
    regenerate_keys = (self.licensee_name != new_name) && (self.submitting? or self.complete?)
    write_attribute(:licensee_name, new_name.strip())
    if regenerate_keys
      for item in self.line_items
        item.license_key = make_license(item.product.code, new_name, item.quantity)
      end
    end
  end

  def first_name=(value)
    write_attribute(:first_name, value.strip())
  end

  def last_name=(value)
    write_attribute(:last_name, value.strip())
  end

  def name
    return self.first_name + ' ' + self.last_name
  end

  def address
    address = self.address1
    address += ', ' + self.address2 if not self.address2.blank?
    return address
  end

  def cc_number
    return @cc_number
  end

  def cc_number=(num)
    t = num.tr('- ', '')
    @cc_number = t
    return if t.length < 4
    self.ccnum = 'X' * (t.length - 4) + t[t.length-4 .. t.length-1]
  end

  def payment_type=(type)
    val = type
    if type
      if ['visa', 'amex', 'discover'].member?(type.downcase())
        val = type.capitalize()
      elsif type.downcase() == 'mastercard'
        val = 'MasterCard'
      end
    end
    write_attribute(:payment_type, val)
  end

  def cc_order?
    return self.payment_type != nil && ['visa', 'mastercard', 'amex', 'discover'].member?(self.payment_type.downcase)
  end

  def paypal_order?
    return self.payment_type != nil && self.payment_type.downcase == 'paypal'
  end

  def gcheckout?
    return self.payment_type != nil && self.payment_type.downcase == 'google checkout'
  end

  def pending?
    return self.status == 'P'
  end

  def complete?
    return self.status == 'C'
  end

  def submitting?
    return self.status == 'S'
  end

  def status=(new_status)
    if (self.pending? or self.submitting?) && new_status == 'C'
      self.email_receipt_when_finishing = true
    end
    write_attribute(:status, new_status)
  end

  def status_description
    case self.status
    when 'C'
      return 'Complete'
    when 'P'
      return 'Pending'
    when 'S'
      return 'Submitting'
    when 'F'
      return 'Failed'
    when 'X'
      return 'Cancelled'
    end
    return self.status
  end

  def coupon_text
    self.coupon.coupon
  end

  def coupon_text=(coupon_text)
    return if !coupon_text || coupon_text.strip == ''
    coupon = Coupon.find_by_coupon(coupon_text.strip)
    if coupon != nil &&
        self.coupon == nil &&
        (coupon.product_code == 'all' || has_item_with_code(coupon.product_code)) &&
        !coupon.expired?
      self.coupon = coupon
    end
  end

  def has_item_with_product_id(product_id)
    return self.line_items.collect {|x| x.product.id if x.quantity > 0}.member?(product_id)
  end

  def has_item_with_code(code)
    return self.line_items.collect {|x| x.product.code if x.quantity > 0}.member?(code)
  end

  def line_item_with_product_id(product_id)
    begin
      product_id = Integer(product_id)
    rescue
      return nil
    end
    items = self.line_items.collect {|x| x if x.product.id == product_id}.compact
    return nil if items.length == 0
    return items[0]
  end

  def line_item_with_product_code(product_code)
    p = Product.find_by_code(product_code)
    return self.line_item_with_product_id(p.id)
  end

  # Add items from form parameters
  def add_form_items(items)
    begin
      for product_id in items.keys
        next if items[product_id].to_s.strip == ''
        item = LineItem.new({:order => self,:product_id => product_id})
        item.quantity = items[product_id].to_i
        next if item.quantity == 0
        return false if item.quantity < 0

        item.unit_price = Product.find(product_id).price
        self.line_items << item
      end
      for item in self.line_items
        item.unit_price = item.volume_price
      end
      return true
    rescue
      logger.error("Could not add form product items: #{$!}")
      return false
    end
  end

  def add_or_update_items(items)
    for product_id in items.keys
      next if items[product_id].to_s.strip == ''
      litem = self.line_item_with_product_id(product_id)
      if litem == nil
        return false if not self.add_form_items({product_id => items[product_id]})
      else
        quantity = items[product_id].to_i
        if quantity <= 0
          litem.destroy()
          self.line_items.delete(litem)
        else
          litem.quantity = quantity
        end
      end
    end
    return true
  end

  # Updates the prices from form
  def update_item_prices(item_prices)
    for product_id in item_prices.keys
      litem = self.line_item_with_product_id(product_id)
      next if litem == nil
      litem.unit_price = item_prices[product_id]
    end
  end

  def promo_coupons
    return @promo_coupons if @promo_coupons
    return []
  end

  # Create new coupons that pertain to this order and return it
  def add_promo_coupons
    self.promo_coupons = []
    # if the order contains Voice Candy, create 3 coupons
#     if self.has_item_with_code('vc')
#       1.upto(3) { |i|
#         coupon = Coupon.new
#         coupon.code = 'vc'
#         coupon.product_code = 'vc'
#         coupon.description = 'Cool friend discount'
#         coupon.amount = 3.00
#         coupon.numdays = 16
#         coupon.save()
#         coupons << coupon
#       }
#     end
    return promo_coupons
  end

  def subscribe_to_list
    return if ListSubscriber.find_by_email(self.email) != nil
    subscriber = ListSubscriber.new
    subscriber.email = self.email
    subscriber.save()
  end

  def save
    # Insert a dash for Japanese zipcodes if it doesn't have one
    if self.country == 'JP' && self.zipcode != nil && self.zipcode.count('-') == 0 && self.zipcode.length > 3
      self.zipcode.insert(3, '-')
    end

    # Take out optional strings
    self.address2 = '' if self.address2 != nil && self.address2.strip == 'optional'
    self.company = '' if self.company != nil && self.company.strip == 'optional'
    self.comment = '' if self.comment != nil && self.comment.strip == 'optional'

    # Save updated relationships
    for item in self.line_items
      if !item.new_record? && item.changed?
        item.save()
      end
    end

    if self.coupon != nil && !self.coupon.new_record? && self.coupon.changed?
      self.coupon.save()
    end

    super()
  end

  def finish_and_save
    if self.status == 'C'
      self.add_promo_coupons()
      for line_item in self.line_items
        if line_item.license_key.nil? then
          line_item.license_key = make_license(line_item.product.code, self.licensee_name, line_item.quantity)
        end
      end
      if self.coupon
        self.coupon.used_count += 1
      end
    end

    self.save()

    if self.email_receipt_when_finishing && !self.gcheckout?
      # Google Checkout orders get the emails delivered when the final OK notification from Google arrives
      OrderMailer.deliver_thankyou(self) if is_live?()
    end
  end

  # PayPal related methods
  def paypal_directcharge(request)
    # The following is needed because MediaTemple puts in two ip addresses in REMOTE_ADDR for some reason
    ip_address = request.env['REMOTE_ADDR']
    ip_address = ip_address.split(',')[0] if ip_address.count(",") != 0
    ip_address = "127.0.0.1" if ip_address == "::1"

    cc_year = self.cc_year.to_s
    if cc_year.length == 2
      cc_year = '20' + cc_year
    elsif cc_year.length == 1
      cc_year = '200' + cc_year
    end

    res = Paypal.directcharge(:firstName => self.first_name,
                              :lastName => self.last_name,
                              :ip => ip_address,
                              :amount => self.total,
                              :itemName => $STORE_PREFS['company_name'] + ' Software',
                              :addressName => 'Billing',
                              :street1 => self.address1,
                              :street2 => self.address2,
                              :cityName => self.city,
                              :stateOrProvince => (self.state.blank?) ? 'N/A' : self.state,
                              :postalCode => self.zipcode,
                              :country => self.country,
                              :creditCardType => self.payment_type,
                              :creditCardNumber => self.cc_number,
                              :cVV2 => self.cc_code,
                              :expMonth => self.cc_month,
                              :expYear => cc_year)
    success = (res.ack == 'Success' || res.ack == 'SuccessWithWarning')
    if success
      self.transaction_number = res.transactionID
    else
      set_order_errors_with_paypal_response(res)
    end
    return success
  end

  def paypal_express_checkout_payment(token, payer_id)
    res = Paypal.express_checkout_payment(:token => token,
                                          :payerID => payer_id,
                                          :amount => self.total)
    success = (res.ack == 'Success' || res.ack == 'SuccessWithWarning')
    if success
      self.transaction_number = res.doExpressCheckoutPaymentResponseDetails.paymentInfo.transactionID
    else
      set_order_errors_with_paypal_response(res)
    end
    return success
  end

  def set_order_errors_with_paypal_response(res)
    if res.ack == 'Failure' || res.ack == 'FailureWithWarning'
      self.failure_reason = ''
      if res.errors.respond_to? 'length'
        errors = res.errors
      else
        errors = [res.errors]
      end

      self.failure_code = errors.collect {|x| x.errorCode}.join(', ')

      self.failure_reason = errors.collect {|error|
        msg = ''
        if error.respond_to? 'longMessage'
          msg = error.longMessage
        elsif error.repond_to? 'shortMessage'
          msg = error.shortMessage
        end
        msg = msg[38..-1] if msg =~ /^This transaction cannot be processed. /
        msg
      }.join("\n")
      if res.respond_to? 'cVV2Code'
        self.failure_reason += "\nThe card security code did not match." if res.cVV2Code == 'N'
      end

      self.errors.add_to_base(self.failure_reason)

      # The 127 limit comes from the schema.
      # TODO: figure out a way to get the limit from the db schema
      if self.failure_reason.length > 127
        self.failure_reason = self.failure_reason[0...127]
      end
    end
  end


  # Google Checkout related methods
  def send_to_google_checkout(edit_cart_url = nil)
    command = $GCHECKOUT_FRONTEND.create_checkout_command
    command.continue_shopping_url = $STORE_PREFS['company_url']
    command.edit_cart_url = edit_cart_url

    for line_item in self.line_items
      command.shopping_cart.create_item do |item|
        item.name = line_item.product.name
        item.description = ""
        item.unit_price = Money.new(line_item.unit_price * 100)
        item.quantity = line_item.quantity

        # Force a license key generation here even though the order status is still P.
        # The order doesn't become status C until we get final notification from Google,
        # but we're still optimistically showing the buyer their license key because otherwise
        # the delay can be as much as 20 minutes on the GCheckout side
        line_item.license_key = make_license(line_item.product.code, self.licensee_name, line_item.quantity)
        line_item.save()

        digital_content = Google4R::Checkout::DigitalContent.new
        digital_content.key = line_item.license_key
        digital_content.description = "#{line_item.product.name}, licensed to #{self.licensee_name}"
        digital_content.display_disposition = 'OPTIMISTIC'

        # NOTE: If you don't like the way the license key is presented on Google Checkout after
        # the buyer completes the purchase, you can also not set the digital_content.key and
        # format everything with digital_content.description. You can even put HTML in there.

        item.digital_content = digital_content
      end
    end

    if self.coupon
      command.shopping_cart.create_item do |item|
        item.name = "Coupon"
        item.description = coupon.description
        item.unit_price = Money.new(-coupon_amount() * 100)
        item.quantity = 1
      end
    end

    command.shopping_cart.private_data = { 'order-id' => [self.id] }

    begin
      res = command.send_to_google_checkout()
      return res.redirect_url
    rescue
      logger.error("An error while talking to google checkout: #{$!}")
      return nil
    end
  end

  def send_to_google_add_merchant_order_number_command
    command = $GCHECKOUT_FRONTEND.create_add_merchant_order_number_command
    command.google_order_number = self.transaction_number
    command.merchant_order_number = self.id
    command.send_to_google_checkout() rescue nil
  end

  def send_to_google_deliver_order_command
    command = $GCHECKOUT_FRONTEND.create_deliver_order_command
    command.google_order_number = self.transaction_number
    command.send_email = false
    command.send_to_google_checkout() rescue nil
  end

  def send_to_google_archive_order_command
    command = $GCHECKOUT_FRONTEND.create_archive_order_command
    command.google_order_number = self.transaction_number
    command.send_to_google_checkout() rescue nil
  end

  @@encodeMap = [ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
'B', 'C', 'D', 'F', 'G', 'H', 'J', 'K', 'L', 'M', 'N', 'P', 'Q', 'R',
'S', 'T', 'V', 'W', 'X', 'Z' ]

  def encode_number(number)
    base = @@encodeMap.length
    encodedString = ""
    while number > 0
      remainder = number % base
      encodedString = @@encodeMap[remainder] + encodedString

       number = ((number - remainder).divmod(base))[0]
    end

    return encodedString
  end

  def generate_order_number
    time = self.order_time

    timestring = "%10.5f" % time.to_f
    timestring.sub!(/\./, "")

    # Convert to our own brand of base 30
    id = encode_number(timestring.to_i)

    # Add random bit at end in the very unlikely event that two orders
    # have the same order time (to microsecond accuracy)

    # With base 30, we want to generate two digits. So 30^2
    max = @@encodeMap.length * @@encodeMap.length

    # Note that it's 3 digits in decimal
    randSalt = encode_number(rand(max))

    while randSalt.length < 2
      randSalt = "0" + randSalt
    end

    id += randSalt

    return id
  end

end

