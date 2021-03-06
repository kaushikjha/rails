module ActiveRecord
  class Relation
    include RelationalCalculations

    delegate :to_sql, :to => :relation
    delegate :length, :collect, :map, :each, :all?, :to => :to_a

    attr_reader :relation, :klass, :preload_associations, :eager_load_associations
    attr_writer :readonly, :preload_associations, :eager_load_associations

    def initialize(klass, relation)
      @klass, @relation = klass, relation
      @preload_associations = []
      @eager_load_associations = []
      @loaded, @readonly = false
    end

    def merge(r)
      raise ArgumentError, "Cannot merge a #{r.klass.name} relation with #{@klass.name} relation" if r.klass != @klass

      joins(r.relation.joins(r.relation)).
        group(r.send(:group_clauses).join(', ')).
        order(r.send(:order_clauses).join(', ')).
        where(r.send(:where_clause)).
        limit(r.taken).
        offset(r.skipped).
        select(r.send(:select_clauses).join(', ')).
        eager_load(r.eager_load_associations).
        preload(r.preload_associations).
        from(r.send(:sources).present? ? r.send(:from_clauses) : nil)
    end

    alias :& :merge

    def preload(*associations)
      spawn.tap {|r| r.preload_associations += Array.wrap(associations) }
    end

    def eager_load(*associations)
      spawn.tap {|r| r.eager_load_associations += Array.wrap(associations) }
    end

    def readonly(status = true)
      spawn.tap {|r| r.readonly = status }
    end

    def select(selects)
      if selects.present?
        relation = spawn(@relation.project(selects))
        relation.readonly = @relation.joins(relation).present? ? false : @readonly
        relation
      else
        spawn
      end
    end

    def from(from)
      from.present? ? spawn(@relation.from(from)) : spawn
    end

    def having(*args)
      return spawn if args.blank?

      if [String, Hash, Array].include?(args.first.class)
        havings = @klass.send(:merge_conditions, args.size > 1 ? Array.wrap(args) : args.first)
      else
        havings = args.first
      end

      spawn(@relation.having(havings))
    end

    def group(groups)
      groups.present? ? spawn(@relation.group(groups)) : spawn
    end

    def order(orders)
      orders.present? ? spawn(@relation.order(orders)) : spawn
    end

    def lock(locks = true)
      case locks
      when String
        spawn(@relation.lock(locks))
      when TrueClass, NilClass
        spawn(@relation.lock)
      else
        spawn
      end
    end

    def reverse_order
      relation = spawn
      relation.instance_variable_set(:@orders, nil)

      order_clause = @relation.send(:order_clauses).join(', ')
      if order_clause.present?
        relation.order(reverse_sql_order(order_clause))
      else
        relation.order("#{@klass.table_name}.#{@klass.primary_key} DESC")
      end
    end

    def limit(limits)
      limits.present? ? spawn(@relation.take(limits)) : spawn
    end

    def offset(offsets)
      offsets.present? ? spawn(@relation.skip(offsets)) : spawn
    end

    def on(join)
      spawn(@relation.on(join))
    end

    def joins(join, join_type = nil)
      return spawn if join.blank?

      join_relation = case join
      when String
        @relation.join(join)
      when Hash, Array, Symbol
        if @klass.send(:array_of_strings?, join)
          @relation.join(join.join(' '))
        else
          @relation.join(@klass.send(:build_association_joins, join))
        end
      else
        @relation.join(join, join_type)
      end

      spawn(join_relation).tap { |r| r.readonly = true }
    end

    def where(*args)
      return spawn if args.blank?

      if [String, Hash, Array].include?(args.first.class)
        conditions = @klass.send(:merge_conditions, args.size > 1 ? Array.wrap(args) : args.first)
        conditions = Arel::SqlLiteral.new(conditions) if conditions
      else
        conditions = args.first
      end

      spawn(@relation.where(conditions))
    end

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

    def find(*ids, &block)
      return to_a.find(&block) if block_given?

      expects_array = ids.first.kind_of?(Array)
      return ids.first if expects_array && ids.first.empty?

      ids = ids.flatten.compact.uniq

      case ids.size
      when 0
        raise RecordNotFound, "Couldn't find #{@klass.name} without an ID"
      when 1
        result = find_one(ids.first)
        expects_array ? [ result ] : result
      else
        find_some(ids)
      end
    end

    def exists?(id = nil)
      relation = select("#{@klass.quoted_table_name}.#{@klass.primary_key}").limit(1)
      relation = relation.where(@klass.primary_key => id) if id
      relation.first ? true : false
    end

    def first
      if loaded?
        @records.first
      else
        @first ||= limit(1).to_a[0]
      end
    end

    def last
      if loaded?
        @records.last
      else
        @last ||= reverse_order.limit(1).to_a[0]
      end
    end

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
      relation = self.class.new(@klass, relation)
      relation.readonly = @readonly
      relation.preload_associations = @preload_associations
      relation.eager_load_associations = @eager_load_associations
      relation
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

    def find_by_attributes(match, attributes, *args)
      conditions = attributes.inject({}) {|h, a| h[a] = args[attributes.index(a)]; h}
      result = where(conditions).send(match.finder)

      if match.bang? && result.blank?
        raise RecordNotFound, "Couldn't find #{@klass.name} with #{conditions.to_a.collect {|p| p.join(' = ')}.join(', ')}"
      else
        result
      end
    end

    def find_or_instantiator_by_attributes(match, attributes, *args)
      guard_protected_attributes = false

      if args[0].is_a?(Hash)
        guard_protected_attributes = true
        attributes_for_create = args[0].with_indifferent_access
        conditions = attributes_for_create.slice(*attributes).symbolize_keys
      else
        attributes_for_create = conditions = attributes.inject({}) {|h, a| h[a] = args[attributes.index(a)]; h}
      end

      record = where(conditions).first

      unless record
        record = @klass.new { |r| r.send(:attributes=, attributes_for_create, guard_protected_attributes) }
        yield(record) if block_given?
        record.save if match.instantiator == :create
      end

      record
    end

    def find_one(id)
      record = where(@klass.primary_key => id).first

      unless record
        conditions = where_clause(', ')
        conditions = " [WHERE #{conditions}]" if conditions.present?
        raise RecordNotFound, "Couldn't find #{@klass.name} with ID=#{id}#{conditions}"
      end

      record
    end

    def find_some(ids)
      result = where(@klass.primary_key => ids).all

      expected_size =
        if @relation.taken && ids.size > @relation.taken
          @relation.taken
        else
          ids.size
        end

      # 11 ids with limit 3, offset 9 should give 2 results.
      if @relation.skipped && (ids.size - @relation.skipped < expected_size)
        expected_size = ids.size - @relation.skipped
      end

      if result.size == expected_size
        result
      else
        conditions = where_clause(', ')
        conditions = " [WHERE #{conditions}]" if conditions.present?

        error = "Couldn't find all #{@klass.name.pluralize} with IDs "
        error << "(#{ids.join(", ")})#{conditions} (found #{result.size} results, but was looking for #{expected_size})"
        raise RecordNotFound, error
      end
    end

    def where_clause(join_string = "\n\tAND ")
      @relation.send(:where_clauses).join(join_string)
    end

    def reverse_sql_order(order_query)
      order_query.to_s.split(/,/).each { |s|
        if s.match(/\s(asc|ASC)$/)
          s.gsub!(/\s(asc|ASC)$/, ' DESC')
        elsif s.match(/\s(desc|DESC)$/)
          s.gsub!(/\s(desc|DESC)$/, ' ASC')
        else
          s.concat(' DESC')
        end
      }.join(',')
    end

  end
end
