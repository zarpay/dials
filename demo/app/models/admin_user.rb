# frozen_string_literal: true

# Stand-in for whatever authenticated admin object a real app has (Devise
# user, ActiveAdmin admin, ...). Dials only needs the object at write time —
# it records class name, id, and a label (here, the email) in the change log.
AdminUser = Data.define(:id, :email)
