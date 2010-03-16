require 'duby'
require 'duby/ast'
require 'duby/jvm/types'
require 'duby/jvm/compiler'
require 'duby/jvm/source_generator/builder'
require 'duby/jvm/source_generator/precompile'
require 'duby/jvm/source_generator/loops'

class String
  def compile(compiler, expression)
    compiler.method.print self if expression
  end
end

module Duby
  module Compiler
    class JavaSource < JVMCompilerBase
      JVMTypes = Duby::JVM::Types
      attr_accessor :lvalue

      Operators = [
        '+', '-', '+@', '-@', '/', '%', '*', '<',
        '<=', '==', '!=', '>=', '>',
        '<<', '>>', '>>>', '|', '&', '^', '~'
      ]
      ArrayOps = [
        '[]', '[]=', 'length'
      ]

      ImplicitReturn = Struct.new(:value)

      def initialize(filename)
        super
        @file = Duby::JavaSource::Builder.new(filename, self)
      end

      def output_type
        "source files"
      end

      def define_method(node)
        super(node, false) do |method, _|
          with :method => method do
            log "Starting new method #{node.name}"
            @method.start

            prepare_binding(node) do
              unless @method.type.nil? || @method.type.void?
                self.return(ImplicitReturn.new(node.body))
              else
                node.body.compile(self, false) if node.body
              end
            end

            log "Method #{node.name} complete!"
            @method.stop
          end
        end
      end

      def annotate(node, annotations)
        node.annotate(annotations)
      end

      def define_optarg_chain(name, arg, return_type,
                              args_for_opt, arg_types_for_opt)
        # declare all args so they get their values
        @method.print "return " unless @method.type.nil? || @method.type.void?
        @method.print "this." unless @static
        @method.print "#{name}("
        @method.print args_for_opt.map(&:name).join(', ')
        @method.print ', 'if args_for_opt.size > 0
        arg.children[0].value.compile(self, true)

        # invoke the next one in the chain
        @method.print ");\n"
      end

      def constructor(node)
        super(node, false) do |method, _|
          with :method => method do
            @method.start
            if node.delegate_args
              delegate = if node.calls_super
                "super"
              else
                "this"
              end
              method.print "#{delegate}("
              node.delegate_args.each_with_index do |arg, index|
                method.print ', ' unless index == 0
                raise "Invalid constructor argument #{arg}" unless arg.expr?(self)
                arg.compile(self, true)
              end
              method.puts ");"
            end

            prepare_binding(node) do
              node.body.compile(self, false) if node.body
            end
            method.stop
          end
        end
      end

      def prepare_binding(scope)
        if scope.has_binding?
          type = scope.binding_type
          @binding = @bindings[type]
          @method.puts "#{type.name} $binding = new #{type.name}();"
        end
        begin
          yield
        ensure
          if scope.has_binding?
            @binding.stop
            @binding = nil
          end
        end
      end

      def define_closure(class_def, expression)
        compiler = ClosureCompiler.new(@file, @type, self)
        compiler.define_class(class_def, expression)
      end

      def return(node)
        if @method.type.nil? || @method.type.void?
          @method.puts 'return;'
          return
        end
        if node.value.expr?(self)
          @method.print 'return '
          node.value.compile(self, true)
          @method.puts ';'
        else
          store_value('return ', node.value)
        end
      end

      def _raise(node)
        if node.expr?(self)
          @method.print 'throw '
          node.compile(self, true)
          @method.puts ';'
        else
          store_value('throw ', node)
        end
      end

      def rescue(node, expression)
        @method.block 'try' do
          maybe_store(node.body, expression)
        end
        node.clauses.each do |clause|
          clause.types.each do |type|
            name = clause.name || 'tmp$ex'
            @method.block "catch (#{type.to_source} #{name})" do
              maybe_store(clause.body, expression)
            end
          end
        end
      end

      def ensure(node, expression)
        @method.block 'try' do
          maybe_store(node.body, expression)
        end
        @method.block 'finally' do
          node.clause.compile(self, false)
        end
      end

      def line(num)
      end

      def declare_local(name, type)
        @method.declare_local(type, name)
      end

      def declare_field(name, type, annotations)
        @class.declare_field(name, type, @static, 'private', annotations)
      end

      def local(scope, name, type)
        name = scoped_local_name(name, scope)
        @method.print name
      end

      def field(name, type, annotations)
        name = name[1..-1]
        declare_field(name, type, annotations)
        @method.print "#{this}.#{name}"
      end

      def this
        @static ? @class.class_name : 'this'
      end

      def local_assign(scope, name, type, expression, value)
        value = value.precompile(self)
        name = scoped_local_name(name, scope)
        if method.local?(name)
          @method.print @lvalue if expression
          @method.print "#{name} = "
          value.compile(self, true)
          @method.puts ';'
        else
          @method.declare_local(type, name) do
            value.compile(self, true)
          end
          if expression
            @method.puts "#{@lvalue}#{name};"
          end
        end
      end

      def field_declare(name, type, annotations)
        name = name[1..-1]
        declare_field(name, type, annotations)
      end

      def local_declare(scope, name, type)
        name = scoped_local_name(name, scope)
        declare_local(name, type)
      end

      def field_assign(name, type, expression, value, annotations)
        name = name[1..-1]
        declare_field(name, type, annotations)
        lvalue = "#{@lvalue if expression}#{this}.#{name} = "
        store_value(lvalue, value)
      end

      def captured_local_declare(scope, name, type)
        unless declared_captures[name]
          declared_captures[name] = type
          @binding.declare_field(name, type, false, '')
        end
      end

      def captured_local(scope, name, type)
        captured_local_declare(scope, name, type)
        @method.print "$binding.#{name}"
      end

      def captured_local_assign(node, expression)
        scope, name, type = node.scope, node.name, node.inferred_type
        captured_local_declare(scope, name, type)
        lvalue = "#{@lvalue if expression}$binding.#{name} = "
        store_value(lvalue, node.value)
      end

      def store_value(lvalue, value)
        if value.is_a? String
          @method.puts "#{lvalue}#{value};"
        elsif value.expr?(self)
          @method.print lvalue
          value.compile(self, true)
          @method.puts ';'
        else
          with :lvalue => lvalue do
            value.compile(self, true)
          end
        end
      end

      def assign(name, value)
        store_value("#{name} = ", value)
        name
      end

      def maybe_store(value, expression)
        if expression
          store_value(@lvalue, value)
        else
          value.compile(self, false)
        end
      end

      def body(body, expression)
        super(body, expression) do |last|
          maybe_store(last, expression)
        end
      end

      def scoped_body(scope, expression)
        @method.block do
          super
        end
      end

      def branch_expression(node)
        node.condition.compile(self, true)
        @method.print ' ? ('
        if node.body
          node.body.compile(self, true)
        else
          @method.print @method.init_value(node.inferred_type)
        end
        @method.print ') : ('
        if node.else
          node.else.compile(self, true)
        else
          @method.print @method.init_value(node.inferred_type)
        end
        @method.print ')'
      end

      def branch(node, expression)
        if expression && node.expr?(self)
          return branch_expression(node)
        end
        predicate = node.condition.predicate.precompile(self)
        @method.print 'if ('
        predicate.compile(self, true)
        @method.block ")" do
          if node.body
            maybe_store(node.body, expression)
          elsif expression
            store_value(@lvalue, @method.init_value(node.inferred_type))
          end
        end
        if node.else || expression
          @method.block 'else' do
            if node.else
              maybe_store(node.else, expression)
            else
              store_value(@lvalue, @method.init_value(node.inferred_type))
            end
          end
        end
      end

      def loop(loop, expression)
        if loop.redo? || loop.post || !loop.condition.predicate.expr?(self)
          loop = ComplexWhileLoop.new(loop, self)
        else
          loop = SimpleWhileLoop.new(loop, self)
        end
        with(:loop => loop) do
          loop.compile(expression)
        end
      end

      def expr?(target, params)
        !([target] + params).any? {|x| x.kind_of? Duby::AST::TempValue}
      end

      def operator(target, op, params, expression)
        simple = expr?(target, params)
        if expression && !simple
          @method.print @lvalue
        end
        if params.size == 0
          # unary operator
          op = op[0,1]
          @method.print op
          target.compile(self, true)
        else
          @method.print '('
          other = params[0]
          target.compile(self, true)
          @method.print " #{op} "
          other.compile(self, true)
          @method.print ')'
        end
        unless expression && simple
          @method.puts ';'
        end
      end

      def compile_args(call)
        call.parameters.map do |param|
          param.precompile(self)
        end
      end

      def self_type
        type = AST::type(@class.name.tr('/', '.'))
        type = type.meta if @static
        type
      end

      def super_call(call, expression)
        super_method_call(this, call, compile_args(call), expression)
      end

      def self_call(call, expression)
        if call.cast?
          args = compile_args(call)
          simple = call.expr?(self)
          @method.print @lvalue if expression && !simple
          @method.print "((#{call.inferred_type.name})("
          args.each{|arg| arg.compile(self, true)}
          @method.print "))"
          @method.puts ';' unless simple && expression
        else
          method_call(this, call, compile_args(call), expression)
        end
      end

      def call(call, expression)
        if Duby::AST::Constant === call.target
          target = call.target.inferred_type.name
        else
          target = call.target.precompile(self)
        end
        params = compile_args(call)

        if Operators.include? call.name
          operator(target, call.name, params, expression)
        elsif call.target.inferred_type.array? && ArrayOps.include?(call.name)
          array_op(target, call.name, params, expression)
        elsif call.name == 'nil?'
          operator(target, '==', ['null'], expression)
        else
          method_call(target, call, params, expression)
        end
      end

      def array_op(target, name, args, expression)
        simple = expr?(target, args)
        index, value = args
        if expression && !simple
          @method.print @lvalue
        end
        target.compile(self, true)
        if name == 'length'
          @method.print '.length'
        else
          @method.print '['
          index.compile(self, true)
          @method.print ']'
          if name == '[]='
            @method.print " = "
            value.compile(self, true)
          end
        end
        unless simple && expression
          @method.puts ';'
        end
      end

      def break(node)
        @loop.break
      end

      def next(node)
        @loop.next
      end

      def redo(node)
        @loop.redo
      end

      # TODO: merge cleanly with method_call logic
      def super_method_call(target, call, params, expression)
        simple = call.expr?(self)
        method = call.method(self)
        unless simple || method.actual_return_type.void?
          @method.print @lvalue if expression
        end
        if method.constructor?
          @method.print "super("
        else
          @method.print "super.#{method.name}("
        end
        params.each_with_index do |param, index|
          @method.print ', ' unless index == 0
          param.compile(self, true)
        end
        if simple && expression
          @method.print ')'
        else
          @method.puts ');'
        end
        if method.actual_return_type.void? && expression
          @method.print @lvalue
          if method.static?
            @method.puts 'null;'
          else
            target.compile(self, true)
            @method.puts ';'
          end
        end

      end

      def method_call(target, call, params, expression)
        simple = call.expr?(self)
        method = call.method(self)
        unless simple || method.actual_return_type.void?
          @method.print @lvalue if expression
        end

        # preamble
        if method.constructor?
          @method.print "new "
          target.compile(self, true)
          @method.print '('
        elsif method.field?
          target.compile(self, true)
          @method.print ".#{method.name}"
          if method.argument_types.size == 1
            @method.print " = ("
          end
        else
          target.compile(self, true)
          @method.print ".#{method.name}("
        end

        # args
        params.each_with_index do |param, index|
          @method.print ', ' unless index == 0
          param.compile(self, true)
        end

        # postamble
        if !method.field? || (method.field? && method.argument_types.size == 1)
          if simple && expression
            @method.print ')'
          else
            @method.puts ');'
          end
        end

        # cleanup
        if method.actual_return_type.void? && expression
          @method.print @lvalue
          if method.static?
            @method.puts 'null;'
          else
            target.compile(self, true)
            @method.puts ';'
          end
        end
      end

      def temp(expression, value=nil)
        assign(@method.tmp(expression.inferred_type), value || expression)
      end

      def empty_array(type, size)
        sizevar = size.precompile(self)
        @method.print "#{@lvalue unless size.expr?(self)}new #{type.name}["
        sizevar.compile(self, true)
        @method.print ']'
      end

      def string(value)
        @method.print value.inspect
      end

      def boolean(value)
        @method.print value ? 'true' : 'false'
      end

      def array(node, expression)
        if expression
          # create unmodifiable list from array (simplest way to do this in Java source)
          @method.print "java.util.Collections.unmodifiableList(java.util.Arrays.asList("

          # elements, as expressions
          comma = false
          node.children.each do |n|
            @method.print ", " if comma
            n.compile(self, true)
            comma = true
          end

          @method.print("))")
        else
          # elements, as non-expressions
          # TODO: ensure they're all reference types!
          node.children.each do |n|
            n.compile(self, false)
          end
        end
      end

      def build_string(nodes, expression)
        if expression
          simple = true
          nodes = nodes.map do |node|
            simple &&= node.expr?(self)
            node.precompile(self)
          end
          log "nodes: #{nodes.inspect}"
          if !simple
            @method.print(lvalue)
          end
          first = true
          unless nodes[0].kind_of?(Duby::AST::String)
            @method.print '""'
            first = false
          end
          nodes.each do |node|
            @method.print ' + ' unless first
            first = false
            node.compile(self, true)
          end
          @method.puts ';' unless simple
        else
          nodes.each {|n| n.compile(self, false)}
        end
      end

      def to_string(body, expression)
        body.compile(self, expression)
      end

      def null
        @method.print 'null'
      end

      def binding_reference
        @method.print '$binding'
      end

      def compile_self
        @method.print 'this'
      end

      def print(node)
        value = node.parameters[0]
        value = value && value.precompile(self)
        if node.println
          @method.print "System.out.println("
        else
          @method.print "System.out.print("
        end
        value.compile(self, true) if value
        @method.puts ');'
      end

      class ClosureCompiler < JavaSource
        def initialize(file, type, parent)
          @file = file
          @type = type
          @parent = parent
        end

        def prepare_binding(scope)
          if scope.has_binding?
            type = scope.binding_type
            @binding = @parent.get_binding(type)
            @method.puts("#{type.name} $binding = this.binding;")
          end
          begin
            yield
          ensure
            if scope.has_binding?
              @binding = nil
            end
          end
        end

        def declared_captures
          @parent.declared_captures(@binding)
        end
      end
    end
  end
end
