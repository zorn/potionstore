require 'csv'

class AdminController < ApplicationController
  # GETs should be safe (see http://www.w3.org/2001/tag/doc/whenToUseGet.html)
  verify :method => :post, :only => [ :destroy, :create, :update ],
  :redirect_to => { :action => :list }

  # Authentication stuff
  before_filter :redirect_to_ssl
  before_filter :check_authentication, :except => [:login]

  def login
    unless params[:username] && params[:password]
      render :action => "login" and return
    end

    if params[:username] == $STORE_PREFS['admin_username'] &&
       params[:password] == $STORE_PREFS['admin_password']
      session[:logged_in] = true
      if session[:intended_url] != nil
        redirect_to session[:intended_url]
      else
        redirect_to :action => 'index'
      end
    else
      flash[:notice] = "Go home kid. This ain't for you."
      render :action => "login"
    end
  end

  def logout
    session[:logged_in] = nil
    redirect_to home_url
  end

  # Dashboard page
  def index
    if Product.count == 0
      flash[:notice] = "This store doesn't have any products! Add some!"
      redirect_to :action => 'products' and return
    end

    revenue_summary()
    @chart = OpenFlashChart.swf_object(500, 170, '/admin/charts/revenue_history_days')
  end

  # The revenue_xxx functions get called through ajax when user chooses different types of reports
  def revenue_summary_amount
    revenue_summary()
    @type = "amount"
    render :partial =>  "revenue_summary"
  end

  def revenue_summary_quantity
    revenue_summary()
    @type = "quantity"
    render :partial =>  "revenue_summary"
  end

  def revenue_summary_percentage
    revenue_summary()
    @type = "percentage"
    render :partial =>  "revenue_summary"
  end

  def revenue_history_days
    @type = "30 Day"
    @chart = OpenFlashChart.swf_object(500, 170, '/admin/charts/revenue_history_days')
    render :partial =>  "revenue_history"
  end

  def revenue_history_weeks
    @type = "26 Week"
    @chart = OpenFlashChart.swf_object(500, 170, '/admin/charts/revenue_history_weeks')
    render :partial =>  "revenue_history"
  end

  def revenue_history_months
    @type = "12 Month"
    @chart = OpenFlashChart.swf_object(500, 170, '/admin/charts/revenue_history_months')
    render :partial =>  "revenue_history"
  end

  #BEW Added new methods for importing eSellerate data
  def importRow(row, headerRow, sku_map)
  	result = nil
    if row.length == headerRow.length
	  rowHash = {}
	  for i in 0..row.length
	  	rowHash[headerRow[i]] = row[i]
	  end
	  if rowHash["TRAN_TYPE"] == "ORDER"
		productID = sku_map[rowHash["SKU"]]
		if (productID != nil)
			newOrder = Order.find_or_create_by_order_number(rowHash["ORDER_NUMBER"])
			newOrder.payment_type = "eSellerate"
			newOrder.first_name = rowHash["FIRST_NAME"]
			newOrder.last_name = rowHash["LAST_NAME"]
			newOrder.licensee_name = rowHash["REGISTRATION_NAME"]
			newOrder.company = rowHash["COMPANY"]
			newOrder.address1 = rowHash["ADDRESS1"]
			newOrder.address2 = rowHash["ADDRESS2"]
			newOrder.city = rowHash["CITY"]
			newOrder.state = rowHash["STATE"]
			newOrder.zipcode = rowHash["POSTAL"]
			newOrder.country = country_code(rowHash["COUNTRY"]) or rowHash["COUNTRY"]
			newOrder.email = rowHash["EMAIL"]
			newOrder.order_time = Date.parse(rowHash["TRAN_DATE"], true)
			newOrder.status = 'C'
			lineItem = LineItem.new({:order => newOrder,:product_id => productID})
			lineItem.unit_price = rowHash["UNIT_PRICE"].to_f
			lineItem.quantity = rowHash["QUANTITY"].to_i
			lineItem.license_key = rowHash["SERIAL_NUMBER"]
			newOrder.line_items << lineItem
			newOrder.save()
			ListSubscriber.create(:email => rowHash["EMAIL"]) if (rowHash["CONTACT_ME"] == "1")
			result = newOrder
		end
	  end
	end
	result
  end
  
  def import
  	@products = Product.find(:all)
  	if params["esellerate_order_file"] != nil
  	  sku_map = {}
  	  (params.select { |key, value| key.match("sku_[0-9]+") }).each { |order_key, order_sku| sku_map[order_sku] = order_key[4..-1].to_i }
	  reader = CSV::IOReader.new(params["esellerate_order_file"])
	  headerRow = reader.shift
	  reader.each{|row| importRow(row, headerRow, sku_map)}
	end
  end

  # Coupon actions
  def generate_coupons
    if params[:form]
      form = params[:form]
      @coupons = []
      1.upto(Integer(form[:quantity])) { |i|
        coupon = Coupon.new
        coupon.code = form[:code]
        coupon.product_code = form[:product_code]
        coupon.description = form[:description]
        coupon.amount = form[:amount]
        coupon.use_limit = form[:use_limit]
        coupon.save()
        @coupons << coupon
      }
      flash[:notice] = 'Coupons generated'
    end
  end

#   def add_coupons # unused
#     if params[:form]
#       form = params[:form]
#       lines = form[:coupons].split("\r\n")
#       lines.reject! {|x| x.strip == ''}
#       for line in lines
#         coupon = Coupon.new
#         coupon.code = form[:code]
#         coupon.coupon = line.strip()
#         coupon.product_code = 'x'
#         coupon.description = form[:description].strip()
#         coupon.amount = form[:amount].strip()
#         coupon.save()
#       end
#     end
#   end

#   def mass_order # unused
#     if params[:form]
#       form = params[:form]
#       for key in form.keys()
#         form[key] = form[key].strip()
#       end
#       lines = form[:people].split("\r\n")
#       lines.reject! {|x| x.strip == ''}
#       for line in lines
#         fname, lname, email = line.split(",").collect{|x| x.strip}
#         order = Order.new

#         # add item
#         order.order_time = Time.now()

#         order.add_form_items(params[:items])
#         order.update_item_prices(params[:item_prices])

#         order.first_name = fname
#         order.last_name = lname
#         order.email = email

#         order.address1 = 'n/a'
#         order.address2 = ''
#         order.city = 'n/a'
#         order.state = 'n/a'
#         order.zipcode = 'n/a'
#         order.country = 'XX'

#         order.payment_type = form[:payment_type]
#         order.cc_number = 'XXXXXXXXXXXXXXXX'
#         order.cc_month = 'n/a'
#         order.cc_year = 'n/a'
#         order.cc_code = 'n/a'

#         order.comment = ''

#         order.status = 'C'
#         order.save()

#         coupons = order.add_promo_coupons()

#         email = OrderMailer.deliver_thankyou(order)
#       end
#     end
#   end

  # Revenue summary
  private
  def revenue_summary
    # NOTE: We have to use SQL because performance is completely unacceptable otherwise

    # helper function
    def last_n_days_sql(days)
      # NOTE: Older mysql should use IFNULL instead of COALESCE
      return "
        select (select count(*)
                  from orders
                 where status = 'C' and
                       lower(payment_type) != 'free' and
                       current_date - #{days-1} <= order_time) as orders,
               sum(line_items.unit_price * quantity)
                 - sum(coalesce(coupons.amount, 0))
                 - sum(line_items.unit_price * quantity * coalesce(percentage, 0) / 100) as revenue,
               sum(quantity) as quantity,
               products.name as product_name

        from orders
             inner join line_items on orders.id = line_items.order_id
             left outer join products on products.id = line_items.product_id
             left outer join coupons on coupons.id = orders.coupon_id

        where status = 'C' and lower(payment_type) != 'free' and current_date - #{days-1} <= order_time

        group by product_name"
    end

    query_results = []
    @num_orders = []
    @revenue = []
    @product_revenue = {}
    @product_quantity = {}
    @product_percentage = {}

    for days in [1, 7, 30, 365]
      query_results << Order.connection.select_all(last_n_days_sql(days))
    end
    @products = query_results[-1].map{|p| p["product_name"]}

    # calculate the numbers to report
    for result in query_results
      orders = 0
      total = 0
      for row in result
        name = row["product_name"]
        @product_revenue[name] = [] if @product_revenue[name] == nil
        @product_quantity[name] = [] if @product_quantity[name] == nil
        @product_revenue[name] << row["revenue"]
        @product_quantity[name] << row["quantity"]
        orders = row["orders"]
        total = total.to_f + row["revenue"].to_f
      end
      @num_orders << orders
      @revenue << total
    end

    for product in @products
      @product_revenue[product].insert(0, 0) while @product_revenue[product].length < 4
      @product_quantity[product].insert(0, 0) while @product_quantity[product].length < 4
      @product_percentage[product] = []
      for i in 0..3
        if @revenue[i].to_f == 0
          @product_percentage[product] << 0
        else
          @product_percentage[product] << @product_revenue[product][i].to_f / @revenue[i].to_f * 100.0
        end
      end
    end

    def last_n_days_revenue(days)
      last_n_days_sql = "
        select sum(line_items.unit_price * quantity)
                  - sum(coalesce(coupons.amount, 0))
                  - sum(line_items.unit_price * quantity * coalesce(percentage, 0) / 100) as revenue

          from orders
               inner join line_items on orders.id = line_items.order_id
               left outer join coupons on coupons.id = orders.coupon_id

         where status = 'C' and lower(payment_type) != 'free' and current_date - #{days-1} <= order_time"
      result = Order.connection.select_all(last_n_days_sql)
      return (result != nil && result.length > 0 && result[0]["revenue"] != nil) ? result[0]["revenue"] : 0
    end

    @month_estimate = 0
    @year_estimate = 0

    daily_avg = last_n_days_revenue(90).to_f / 90.0

    # Calculate a very simple sales projection.
    # Takes the average daily sales from the last 90 days to extrapolate the sales
    # for the remaining days of the current month and the next 365 days
    today = Date.today
    days_in_current_month = Date.civil(today.year, today.month, -1).day

    if result != nil and result.length > 0
      @month_estimate = last_n_days_revenue(today.day).to_f + daily_avg * (days_in_current_month - today.day)
      @year_estimate = daily_avg * 365
    end
  end

end
require 'csv'

require 'csv'

require 'csv'

require 'csv'

require 'csv'

