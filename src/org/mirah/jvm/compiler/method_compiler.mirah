# Copyright (c) 2012 The Mirah project authors. All Rights Reserved.
# All contributing project authors may be found in the NOTICE file.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

package org.mirah.jvm.compiler

import java.util.logging.Logger
import mirah.lang.ast.*
import org.mirah.jvm.types.JVMType
import org.jruby.org.objectweb.asm.*
import org.jruby.org.objectweb.asm.Type as AsmType
import org.jruby.org.objectweb.asm.commons.GeneratorAdapter


import java.util.List

class MethodCompiler < BaseCompiler
  def self.initialize:void
    @@log = Logger.getLogger(ClassCompiler.class.getName)
  end
  def initialize(context:Context, flags:int, name:String)
    super(context)
    @flags = flags
    @name = name
    @locals = {}
    @args = {}
  end
  
  def isVoid
    @descriptor.getDescriptor.endsWith(")V")
  end
  
  def method
    @builder
  end
  
  def compile(cv:ClassVisitor, mdef:MethodDefinition):void
    @builder = createBuilder(cv, mdef)
    context[AnnotationCompiler].compile(mdef.annotations, @builder)
    isExpression = isVoid() ? nil : Boolean.TRUE
    if (@flags & Opcodes.ACC_ABSTRACT) == 0
      visit(mdef.body, isExpression)
      @builder.returnValue
    end
    @builder.endMethod
  end

  def compile(node:Node)
    visit(node, Boolean.TRUE)
  end

  def collectArgNames(mdef:MethodDefinition):void
    i = 0
    args = mdef.arguments
    args.required_size.times do |a|
      @args[args.required(a).name.identifier] = Integer.valueOf(i)
      i += 1
    end
    args.optional_size.times do |a|
      @args[args.optional(a).name.identifier] = Integer.valueOf(i)
      i += 1
    end
    if args.rest
      @args[args.rest.name.identifier] = Integer.valueOf(i)
      i += 1
    end
    args.required2_size.times do |a|
      @args[args.required2(a).name.identifier] = Integer.valueOf(i)
      i += 1
    end
  end

  def createBuilder(cv:ClassVisitor, mdef:MethodDefinition)
    type = getInferredType(mdef)
    returnType = JVMType(type.returnType)
    if @name.endsWith("init>")
      returnType = typer.type_system.getVoidType.resolve
    end
    @descriptor = methodDescriptor(@name, JVMType(returnType), type.parameterTypes)
    @selfType = JVMType(getScope(mdef).selfType.resolve)
    superclass = @selfType.superclass
    @superclass = if superclass
     superclass.getAsmType
    else
      AsmType.getType(Object.class)
    end
    collectArgNames(mdef)
    GeneratorAdapter.new(@flags, @descriptor, nil, nil, cv)
  end
  
  def recordPosition(position:Position)
    @builder.visitLineNumber(position.startLine, @builder.mark) if position
  end
  
  def defaultValue(type:JVMType)
    if type.isPrimitive
      if 'long'.equals(type.name)
        @builder.push(long(0))
      elsif 'double'.equals(type.name)
        @builder.push(double(0))
      elsif 'float'.equals(type.name)
        @builder.push(float(0))
      else
        @builder.push(0)
      end
    else
      @builder.push(String(nil))
    end
  end
  
  def visitFixnum(node, expression)
    if expression
      isLong = "long".equals(getInferredType(node).name)
      recordPosition(node.position)
      if isLong
        @builder.push(node.value)
      else
        @builder.push(int(node.value))
      end
    end
  end
  def visitFloat(node, expression)
    if expression
      isFloat = "float".equals(getInferredType(node).name)
      recordPosition(node.position)
      if isFloat
        @builder.push(float(node.value))
      else
        @builder.push(node.value)
      end
    end
  end
  def visitBoolean(node, expression)
    if expression
      recordPosition(node.position)
      @builder.push(node.value ? 1 : 0)
    end
  end
  def visitSimpleString(node, expression)
    if expression
      recordPosition(node.position)
      @builder.push(node.value)
    end
  end
  def visitNull(node, expression)
    value = String(nil)
    if expression
      recordPosition(node.position)
      @builder.push(value)
    end
  end
  
  def visitSuper(node, expression)
    @builder.loadThis
    @builder.loadArgs
    recordPosition(node.position)
    # This is a poorly named method, really it's invokeSpecial
    @builder.invokeConstructor(@superclass, @descriptor)
    if expression && isVoid
      @builder.loadThis
    elsif expression.nil? && !isVoid
      @builder.pop
    end
  end
  
  def visitLocalAccess(local, expression)
    if expression
      recordPosition(local.position)
      name = local.name.identifier
      index = @locals[name]
      if index
        @builder.loadLocal(Integer(index).intValue)
      else
        index = @args[name]
        @builder.loadArg(Integer(index).intValue)
      end
    end
  end

  def visitLocalAssignment(local, expression)
    visit(local.value, Boolean.TRUE)
    @builder.dup if expression
    name = local.name.identifier
    index = @locals[name]
    if index.nil?
      # TODO put variable name into debug info
      type = getInferredType(local).getAsmType
      index = Integer.valueOf(@builder.newLocal(type))
      @locals[name] = index
    end
    recordPosition(local.position)
    @builder.storeLocal(Integer(index).intValue)
  end
  
  def visitCall(call, expression)
    compiler = CallCompiler.new(self, call.position, call.target, call.name.identifier, call.parameters)
    compiler.compile(expression != nil)
  end
  
  def visitNodeList(node, expression)
    if node.size == 0
      if expression
        defaultValue(getInferredType(node))
      else
        @builder.visitInsn(Opcodes.NOP)
      end
    else
      super
    end
  end
  
  def visitIf(node, expression)
    compile(node.condition)
    elseLabel = @builder.newLabel
    endifLabel = @builder.newLabel
    if getInferredType(node.condition).isPrimitive
      @builder.ifZCmp(GeneratorAdapter.EQ, elseLabel)
    else
      @builder.ifNull(elseLabel)
    end
    visit(node.body, expression)
    @builder.goTo(endifLabel)
    @builder.mark(elseLabel)
    visit(node.elseBody, expression)
    @builder.mark(endifLabel)
  end
end