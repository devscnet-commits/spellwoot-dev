class CreateClosingRequirements < ActiveRecord::Migration[7.0]
  def change
    create_table :closing_requirements do |t|
      t.references :operational_flow, null: false, foreign_key: true
      t.string :attribute_key, null: false
      t.jsonb :condition, null: false, default: {}
      t.integer :sort_order, null: false, default: 0

      t.timestamps
    end

    add_index :closing_requirements, %i[operational_flow_id attribute_key], unique: true, name: 'idx_closing_requirements_flow_attribute'
  end
end
