class AddOrderNumber < ActiveRecord::Migration
  def self.up
  	add_column :orders, :order_number, :string
    add_index "orders", ["order_number"], :name => "order_number"
  end

  def self.down
  	remove_column :orders, :order_number
  end
end
