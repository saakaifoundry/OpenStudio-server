class MasterNode
  include Mongoid::Document
  include Mongoid::Timestamps

  field :ip_address, :type => String

end