module ActiveRecord
  class Relation
    include QueryMethods, FinderMethods, CalculationMethods

    delegate :to_sql, :to => :relation
    delegate :length, :collect, :map, :each, :all?, :to => :to_a

    attr_reader :relation, :klass, :preload_associations, :eager_load_associations
    attr_writer :readonly, :preload_associations, :eager_load_associations, :table

    def initialize(klass, relation)
      @klass, @relation = klass, relation
      @preload_associations = []
      @eager_load_associations = []
      @loaded, @readonly = false
    end

    def merge(r)
      raise ArgumentError, "Cannot merge a #{r.klass.name} relation with #{@klass.name} relation" if r.klass != @klass

      merged_relation = spawn(table).eager_load(r.eager_load_associations).preload(r.preload_associations)
      merged_relation.readonly = r.readonly

      [self.relation, r.relation].each do |arel|
        merged_relation = merged_relation.
          joins(arel.joins(arel)).
          group(arel.groupings).
          order(arel.send(:order_clauses).join(', ')).
          limit(arel.taken).
          offset(arel.skipped).
          select(arel.send(:select_clauses)).
          from(arel.sources)
      end

      merged_wheres = @relation.wheres

      r.wheres.each do |w|
        if w.is_a?(Arel::Predicates::Equality)
          merged_wheres = merged_wheres.reject {|p| p.is_a?(Arel::Predicates::Equality) && p.operand1.name == w.operand1.name }
        end

        merged_wheres << w
      end

      merged_relation.where(*merged_wheres)
    end

    alias :& :merge

    def respond_to?(method, include_private = false)
      return true if @relation.respond_to?(method, include_private) || Array.method_defined?(method)

      if match = DynamicFinderMatch.match(method)
        return true if @klass.send(:all_attributes_exists?, match.attribute_names)
      elsif match = DynamicScopeMatch.match(method)
        return true if @klass.send(:all_attributes_exists?, match.attribute_names)
      else
        super
      end
    end

    def to_a
      return @records if loaded?

      @records = if @eager_load_associations.any?
        begin
          @klass.send(:find_with_associations, {
            :select => @relation.send(:select_clauses).join(', '),
            :joins => @relation.joins(relation),
            :group => @relation.send(:group_clauses).join(', '),
            :order => @relation.send(:order_clauses).join(', '),
            :conditions => where_clause,
            :limit => @relation.taken,
            :offset => @relation.skipped,
            :from => (@relation.send(:from_clauses) if @relation.send(:sources).present?)
            },
            ActiveRecord::Associations::ClassMethods::JoinDependency.new(@klass, @eager_load_associations, nil))
        rescue ThrowResult
          []
        end
      else
        @klass.find_by_sql(@relation.to_sql)
      end

      @preload_associations.each {|associations| @klass.send(:preload_associations, @records, associations) }
      @records.each { |record| record.readonly! } if @readonly

      @loaded = true
      @records
    end

    alias all to_a

    def size
      loaded? ? @records.length : count
    end

    def empty?
      loaded? ? @records.empty? : count.zero?
    end

    def any?
      if block_given?
        to_a.any? { |*block_args| yield(*block_args) }
      else
        !empty?
      end
    end

    def many?
      if block_given?
        to_a.many? { |*block_args| yield(*block_args) }
      else
        @relation.send(:taken).present? ? to_a.many? : size > 1
      end
    end

    def destroy_all
      to_a.each {|object| object.destroy}
      reset
    end

    def delete_all
      @relation.delete.tap { reset }
    end

    def delete(id_or_array)
      where(@klass.primary_key => id_or_array).delete_all
    end

    def loaded?
      @loaded
    end

    def reload
      @loaded = false
      reset
    end

    def reset
      @first = @last = nil
      @records = []
      self
    end

    def spawn(relation = @relation)
      relation = Relation.new(@klass, relation)
      relation.readonly = @readonly
      relation.preload_associations = @preload_associations
      relation.eager_load_associations = @eager_load_associations
      relation.table = table
      relation
    end

    def table
      @table ||= Arel::Table.new(@klass.table_name, Arel::Sql::Engine.new(@klass))
    end

    def primary_key
      @primary_key ||= table[@klass.primary_key]
    end

    protected

    def method_missing(method, *args, &block)
      if @relation.respond_to?(method)
        @relation.send(method, *args, &block)
      elsif Array.method_defined?(method)
        to_a.send(method, *args, &block)
      elsif match = DynamicFinderMatch.match(method)
        attributes = match.attribute_names
        super unless @klass.send(:all_attributes_exists?, attributes)

        if match.finder?
          find_by_attributes(match, attributes, *args)
        elsif match.instantiator?
          find_or_instantiator_by_attributes(match, attributes, *args, &block)
        end
      else
        super
      end
    end

    def where_clause(join_string = " AND ")
      @relation.send(:where_clauses).join(join_string)
    end

  end
end
