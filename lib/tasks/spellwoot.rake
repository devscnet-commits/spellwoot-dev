namespace :spellwoot do
  desc 'Create default custom attributes (won/lost) for all existing accounts'
  task setup_default_attributes: :environment do
    Account.find_each do |account|
      account.send(:create_default_custom_attributes)
      print '.'
    end
    puts "\nDone."
  end
end
