require "roxml/utils"

module ROXML
  class RequiredElementMissing < ArgumentError # :nodoc:
  end

  #
  # Internal base class that represents an XML - Class binding.
  #
  class XMLRef # :nodoc:
    attr_reader :opts

    def initialize(opts, instance)
      @opts = opts
      @instance = instance
    end

    def blocks
      opts.blocks || []
    end

    def to_xml(instance)
      val = instance.__send__(opts.accessor)
      opts.to_xml.respond_to?(:call) ? opts.to_xml.call(val) : val
    end

    def name
      opts.name_explicit? ? opts.name : conventionize(opts.name)
    end

    def xpath_name
      namespacify(name)
    end

    def value_in(xml)
      xml = XML::Node.from(xml)
      value = fetch_value(xml)
      value = opts.default if opts.default && (value.nil? || Utils.string_blank?(value.to_s))

      value = apply_blocks(value)
      value = freeze(value) if value && opts.frozen?
      value
    end

  private
    def conventionize(what)
      convention ||= @instance.class.respond_to?(:roxml_naming_convention) && @instance.class.roxml_naming_convention
      if !Utils.string_blank?(what.to_s) && convention.respond_to?(:call)
        URI.decode_www_form_component(convention.call(URI.encode_www_form_component(what)))
      else
        what
      end
    end

    def namespacify(what)
      if !Utils.string_blank?(what.to_s) && opts.namespace != false && ns = [opts.namespace, @instance.class.roxml_namespace, @default_namespace].compact.map(&:to_s).first
        require "rexml/xpath_parser"

        parser = REXML::Parsers::XPathParser.new
        parsed = parser.parse what

        parsed.each_cons(4).with_index.each do |a,i|
          if a[0..2] == [:child, :qname, ""]
            if ns == "*"
              parsed[i+1,3] = [:any, :predicate, [:eq, [:function, "local-name", []], [:literal, a[3]]]] if a[3] != "*"
            else
              a[2].replace ns
            end
          end
        end

        parser.abbreviate parsed
      else
        what
      end
    end

    def apply_blocks(val)
      blocks.inject(val) {|val, block| block.call(val) }
    rescue Exception => ex
      raise ex, "#{opts.accessor}: #{ex.message}"
    end

    def freeze(val)
      val.each(&:freeze) if val.is_a?(Enumerable)
      val.freeze
    end

    def xpath
      opts.wrapper ? "#{namespacify(opts.wrapper)}/#{xpath_name}" : xpath_name.to_s
    end

    def auto_wrapper
      namespacify(conventionize(@instance.class.roxml_inflector.pluralize(opts.name)))
    end

    def auto_xpath
      "#{auto_wrapper}/#{xpath_name}" if opts.array?
    end

    def several?
      opts.array?
    end

    def wrap(xml, opts = {:always_create => false})
      wrap_with = defined?(@auto_vals) && @auto_vals ? auto_wrapper : self.opts.wrapper

      return xml if !wrap_with || xml.name == wrap_with

      wraps = wrap_with.to_s.split('/')
      wraps.inject(xml) do |node,wrap|
        if !opts[:always_create] && (child = node.children.find {|c| c.name == wrap })
          child
        else
          XML.add_node(node, wrap)
        end
      end
    end

    def nodes_in(xml)
      @default_namespace = XML.default_namespace(xml)
      vals = XML.search(xml, xpath, @instance.class.roxml_namespaces)

      if several? && vals.empty? && !opts.wrapper && auto_xpath
        vals = XML.search(xml, auto_xpath, @instance.class.roxml_namespaces)
        @auto_vals = !vals.empty?
      end

      if vals.empty?
        raise RequiredElementMissing, "#{name} from #{xml} for #{opts.accessor}" if opts.required?
        opts.default
      elsif several?
        vals.map do |val|
          yield val
        end
      else
        yield(vals.first)
      end
    end
  end

  # Interal class representing an XML attribute binding
  #
  # In context:
  #  <element attribute="XMLAttributeRef">
  #   XMLTextRef
  #  </element>
  class XMLAttributeRef < XMLRef # :nodoc:
    # Updates the attribute in the given XML block to
    # the value provided.
    def update_xml(xml, values)
      if opts.array?
        values.each do |value|
          wrap(xml, :always_create => true).tap do |node|
            XML.set_attribute(node, name, value.to_s)
          end
        end
      else
        wrap(xml).tap do |xml|
          XML.set_attribute(xml, name, values.to_s)
        end
      end
    end

  private
    def fetch_value(xml)
      nodes_in(xml) do |node|
        node.value
      end
    end

    def xpath_name
      "@#{name}"
    end
  end

  # Interal class representing XML content text binding
  #
  # In context:
  #  <element attribute="XMLAttributeRef">
  #   XMLTextRef
  #  </element>
  class XMLTextRef < XMLRef # :nodoc:
    # Updates the text in the given _xml_ block to
    # the _value_ provided.
    def update_xml(xml, value)
      wrap(xml).tap do |xml|
        if opts.content?
          add(xml, value)
        elsif opts.name?
          xml.name = value
        elsif opts.array?
          value.each do |v|
            add(XML.add_node(xml, name), v)
          end
        else
          add(XML.add_node(xml, name), value)
        end
      end
    end

  private
    def fetch_value(xml)
      if opts.content? || opts.name?
        value =
          if opts.content?
            xml.content.to_s
          elsif opts.name?
            xml.name
          end

        if Utils.string_blank?(value.to_s)
          raise RequiredElementMissing, "#{name} from #{xml} for #{opts.accessor}" if opts.required?
          opts.default
        else
          value
        end
      else
        nodes_in(xml) do |node|
          node.content
        end
      end
    end

    def add(dest, value)
      if opts.cdata?
        XML.add_cdata(dest, value.to_s)
      else
        XML.set_content(dest, value.to_s)
      end
    end
  end

  class XMLNameSpaceRef < XMLRef # :nodoc:
    private
      def fetch_value(xml)
        xml.namespace.prefix
      end
  end

  class XMLHashRef < XMLTextRef # :nodoc:
    def initialize(opts, inst)
      super(opts, inst)
      @key = opts.hash_definition.key.to_ref(inst)
      @value = opts.hash_definition.value.to_ref(inst)
    end

    def several?
      true
    end

    # Updates the composed XML object in the given XML block to
    # the value provided.
    def update_xml(xml, value)
      wrap(xml).tap do |xml|
        value.each_pair do |k, v|
          node = XML.add_node(xml, opts.hash_definition.wrapper)
          @key.update_xml(node, k)
          @value.update_xml(node, v)
        end
      end
    end

  private
    def fetch_value(xml)
      nodes_in(xml) do |node|
        [@key.value_in(node), @value.value_in(node)]
      end
    end

    def apply_blocks(vals)
      unless blocks.empty?
        vals.collect! do |kvp|
          super(kvp)
        end
      end
      to_hash(vals) if vals
    end

    def freeze(vals)
      vals.each_pair{|k, v| k.freeze; v.freeze }
      vals.freeze
    end

    def to_hash(array)
      hash = array.inject({}) do |result, (k, v)|
        result[k] ||= []
        result[k] << v
        result
      end
      hash.each_pair do |k, v|
        hash[k] = v.first if v.size == 1
      end
    end
  end

  class XMLObjectRef < XMLTextRef # :nodoc:
    # Updates the composed XML object in the given XML block to
    # the value provided.
    def update_xml(xml, value)
      wrap(xml).tap do |xml|
        params = {:name => name, :namespace => opts.namespace}
        if opts.array?
          value.each do |v|
            XML.add_child(xml, v.to_xml(params))
          end
        elsif value.is_a?(ROXML)
          XML.add_child(xml, value.to_xml(params))
        else
          XML.add_node(xml, name).tap do |node|
            XML.set_content(node, value.to_xml)
          end
        end
      end
    end

  private
    def fetch_value(xml)
      nodes_in(xml) do |node|
        if opts.sought_type.respond_to? :from_xml
          opts.sought_type.from_xml(node)
        else
          opts.sought_type.new(node)
        end
      end
    end
  end
end
