-- Binary Template plugin for REHex
-- Copyright (C) 2021-2022 Daniel Collins <solemnwarning@solemnwarning.net>
--
-- This program is free software; you can redistribute it and/or modify it
-- under the terms of the GNU General Public License version 2 as published by
-- the Free Software Foundation.
--
-- This program is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
-- FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
-- more details.
--
-- You should have received a copy of the GNU General Public License along with
-- this program; if not, write to the Free Software Foundation, Inc., 51
-- Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

local ArrayValue     = require 'executor.arrayvalue'
local FileArrayValue = require 'executor.filearrayvalue'
local FileValue      = require 'executor.filevalue'
local ImmediateValue = require 'executor.immediatevalue'
local PlainValue     = require 'executor.plainvalue'
local StructValue    = require 'executor.structvalue'

local M = {}

local FRAME_TYPE_BASE     = "base"
local FRAME_TYPE_STRUCT   = "struct"
local FRAME_TYPE_FUNCTION = "function"
local FRAME_TYPE_SCOPE    = "scope"

local FLOWCTRL_TYPE_RETURN   = 1
local FLOWCTRL_TYPE_BREAK    = 2
local FLOWCTRL_TYPE_CONTINUE = 4

local _find_type;
local _builtin_types

local _eval_number;
local _eval_string;
local _eval_ref;
local _eval_add;
local _numeric_op_func;
local _eval_equal
local _eval_not_equal
local _eval_bitwise_not
local _eval_logical_not
local _eval_logical_and;
local _eval_logical_or;
local _eval_postfix_increment
local _eval_postfix_decrement
local _eval_unary_plus
local _eval_unary_minus
local expand_value
local _eval_variable;
local _eval_local_variable
local _eval_assign
local _eval_call;
local _eval_return
local _eval_func_defn;
local _eval_struct_defn
local _eval_typedef
local _eval_enum
local _eval_if
local _eval_for
local _eval_switch
local _eval_block
local _eval_break
local _eval_continue
local _eval_cast
local _eval_ternary
local _eval_statement;
local _exec_statements;

local _ops

local function _map(src_table, func)
	local dst_table = {}
	
	for k,v in pairs(src_table)
	do
		dst_table[k] = func(src_table[k])
	end
	
	return dst_table
end

local function _sorted_pairs(t)
	local keys_sorted = {}
	
	for k in pairs(t)
	do
		table.insert(keys_sorted, k)
	end
	
	table.sort(keys_sorted)
	
	local i = 0
	
	return function()
		i = i + 1
		return keys_sorted[i], t[ keys_sorted[i] ]
	end
end

local function _topmost_frame_of_type(context, type)
	for i = #context.stack, 1, -1
	do
		if context.stack[i].frame_type == type
		then
			return context.stack[i]
		end
	end
	
	return nil
end

local function _can_do_flowctrl_here(context, flowctrl_type)
	for i = #context.stack, 1, -1
	do
		local frame = context.stack[i]
		
		if frame.handles_flowctrl_types ~= nil and (frame.handles_flowctrl_types & flowctrl_type) == flowctrl_type
		then
			return true
		end
		
		if frame.blocks_flowctrl_types ~= nil and (frame.blocks_flowctrl_types & flowctrl_type) == flowctrl_type
		then
			return false
		end
	end
	
	return false
end

local function _template_error(context, error_message, filename, line_num)
	local statement = context.st_stack[#context.st_stack];
	
	if filename == nil then filename = statement[1] end
	if line_num == nil then line_num = statement[2] end
	
	error(error_message .. " at " .. filename .. ":" .. line_num, 0)
end

--
-- Type system
--

-- Placeholder for ... in builtin function parameters. Not a valid type in most contexts but the
-- _eval_call() function handles this specific object specially.
local _variadic_placeholder = {}

local function _make_overlay_type(base_type, child_type)
	local new_type = {};
	
	for k,v in pairs(base_type)
	do
		new_type[k] = v
	end
	
	for k,v in pairs(child_type)
	do
		new_type[k] = v
	end
	
	return new_type
end

local function _make_named_type(name, type_info)
	return _make_overlay_type(type_info, { name = name })
end

local function _make_aray_type(type_info)
	return _make_overlay_type(type_info, { is_array = true })
end

local function _make_nonarray_type(type_info)
	return _make_overlay_type(type_info, { is_array = false })
end

local function _make_ref_type(type_info)
	return _make_overlay_type(type_info, { is_ref = true })
end

local function _make_const_type(type_info)
	return _make_overlay_type(type_info, { is_const = true })
end

local function _get_type_name(type)
	if type == _variadic_placeholder
	then
		return "..."
	elseif type == nil
	then
		return "void"
	end
	
	local type_name
	
	if type.name ~= nil
	then
		type_name = type.name
	elseif type.base == "struct"
	then
		if type.struct_name ~= nil
		then
			type_name = "struct " .. type.struct_name
		else
			type_name = "<anonymous struct>"
		end
	else
		error("Internal error: unknown type in _get_type_name()")
	end
	
	if type.is_const
	then
		type_name = "const " .. type_name
	end
	
	if type.is_array
	then
		if type.array_size ~= nil
		then
			type_name = type_name .. "[" .. type.array_size .. "]"
		else
			type_name = type_name .. "[]"
		end
	end
	
	if type.is_ref
	then
		type_name = type_name .. "&"
	end
	
	return type_name
end

local function _make_signed_type(context, type_info)
	if type_info.signed_overlay ~= nil
	then
		local new_type = _make_overlay_type(type_info, type_info.signed_overlay)
		
		new_type.name = "signed " .. new_type.name:gsub("^signed ", ""):gsub("^unsigned ", "")
		
		return new_type
	else
		_template_error(context, "Attempt to create invalid 'signed' version of type '" .. _get_type_name(type_info) .. "'")
	end
end

local function _make_unsigned_type(context, type_info)
	if type_info.unsigned_overlay ~= nil
	then
		local new_type = _make_overlay_type(type_info, type_info.unsigned_overlay)
		
		new_type.name = "unsigned " .. new_type.name:gsub("^signed ", ""):gsub("^unsigned ", "")
		
		return new_type
	else
		_template_error(context, "Attempt to create invalid 'unsigned' version of type '" .. _get_type_name(type_info) .. "'")
	end
end

local function _type_is_string(type_info)
	return type_info ~= nil and not type_info.is_array and type_info.base == "string"
end

local function _type_is_char_array(type_info)
	return type_info ~= nil and type_info.is_array and type_info.type_key == _builtin_types.char.type_key
end

local function _type_is_number(type_info)
	return type_info ~= nil and not type_info.is_array and type_info.base == "number"
end

local function _type_is_stringish(type_info)
	return _type_is_string(type_info) or _type_is_char_array(type_info)
end

local function _stringify_value(type_info, value)
	if _type_is_string(type_info)
	then
		return value:get()
	elseif _type_is_char_array(type_info)
	then
		local bytes = {}
		
		for i = 1, #value
		do
			local byte = value[i]:get()
			if byte == 0
			then
				break
			end
			
			table.insert(bytes, byte)
		end
		
		return string.char(table.unpack(bytes))
	elseif _type_is_number(type_info)
	then
		return value:get() .. ""
	else
		error("Internal error: Unexpected type '" .. _get_type_name(type_info) .. "' passed to _stringify_value()")
	end
end

local function _type_assignable(dst_t, src_t)
	if dst_t == nil or src_t == nil
	then
		-- "void" can't be assigned anywhere
		return false
	end
	
	if dst_t.is_ref
	then
		-- References can only be made when src/dst are EXACTLY the same type
		-- (typedef aliases match too)
		
		return dst_t.type_key == src_t.type_key
	end
	
	if (_type_is_string(dst_t) and _type_is_char_array(src_t)) or (_type_is_char_array(dst_t) and _type_is_string(src_t))
	then
		-- can assign between char[] and string
		return true
	end
	
	if (not not dst_t.is_array) ~= (not not src_t.is_array)
	then
		-- can't assign array to non-array or vice-versa
		return false
	end
	
	if dst_t.base == "struct" and src_t.base == "struct"
	then
		-- can assign structs if the same root type
		return dst_t.type_key == src_t.type_key
	end
	
	if dst_t.base == src_t.base
	then
		-- can assign the same base types (numeric to numeric and string to string)
		return true
	end
	
	-- unsupported conversion
	return false
end

local function _assign_value(context, dst_type, dst_val, src_type, src_val)
	if dst_type == nil or src_type == nil
	then
		_template_error(context, "can't assign '" .. _get_type_name(src_type) .. "' to type '" .. _get_type_name(dst_type) .. "'")
	end
	
	if _type_is_string(dst_type) and _type_is_char_array(src_type)
	then
		-- Assignment from char[] to string - set the string to the chars from the array
		dst_val:set(_stringify_value(src_type, src_val))
		
		return
	elseif _type_is_char_array(dst_type) and _type_is_string(src_type)
	then
		-- Assignment from string to char[] - copy characters into the string up to the
		-- end of the array/string and fill any remaining space with zeros.
		
		local src_str = src_val:get()
		local src_len = src_str:len()
		
		local i = 1
		
		while i <= #dst_val and i <= src_len
		do
			dst_val[i]:set(src_str:byte(i))
			i = i + 1
		end
		
		while i <= #dst_val
		do
			dst_val[i]:set(0)
			i = i + 1
		end
		
		return
	end
	
	if (not not dst_type.is_array) ~= (not not src_type.is_array)
	then
		_template_error(context, "can't assign '" .. _get_type_name(src_type) .. "' to type '" .. _get_type_name(dst_type) .. "'")
	end
	
	local do_assignment = function(dst_val, src_val)
		if dst_type.base == "struct" and src_type.base == "struct" and dst_type.type_key == src_type.type_key
		then
			for name,src_pair in pairs(src_val)
			do
				local member_type = src_pair[1]
				local src_member = src_pair[2]
				local dst_member = dst_val[name][2]
				
				_assign_value(context, member_type, dst_member, member_type, src_member)
			end
		elseif dst_type.base ~= "struct" and dst_type.base == src_type.base
		then
			dst_val:set(src_val:get())
		else
			_template_error(context, "can't assign '" .. _get_type_name(src_type) .. "' to type '" .. _get_type_name(dst_type) .. "'")
		end
	end
	
	if dst_type.is_array
	then
		if #dst_val ~= #src_val
		then
			
		end
		
		for i = 1, #dst_val
		do
			do_assignment(dst_val[i], src_val[i])
		end
	else
		do_assignment(dst_val, src_val)
	end
end

local function _make_value_from_value(context, dst_type, src_type, src_val, move_if_possible)
	if _type_is_string(dst_type) and _type_is_char_array(src_type)
	then
		-- Assignment from char[] to string - set the string to the chars from the array
		return PlainValue:new(_stringify_value(src_type, src_val))
	elseif _type_is_char_array(dst_type) and _type_is_string(src_type)
	then
		-- Assignment from string to char[] - copy characters into the string up to the
		-- end of the array/string and fill any remaining space with zeros.
		
		local dst_val = ArrayValue:new()
		
		local src_str = src_val:get()
		local src_len = src_str:len()
		
		for i = 1, src_len
		do
			dst_val[i] = PlainValue:new(src_str:byte(i))
		end
		
		return dst_val
	end
	
	if (not dst_type.is_array) ~= (not src_type.is_array)
		or dst_type.base ~= src_type.base
		or (dst_type.base == "struct" and dst_type.type_key ~= src_type.type_key)
	then
		_template_error(context, "can't convert '" .. _get_type_name(src_type) .. "' to type '" .. _get_type_name(dst_type) .. "'")
	end
	
	if src_type.is_array
	then
		local dst_elem_type = _make_nonarray_type(dst_type)
		local src_elem_type = _make_nonarray_type(src_type)
		
		local dst_val = ArrayValue:new()
		
		for i = 1, #src_val
		do
			dst_val[i] = _make_value_from_value(context, dst_elem_type, src_elem_type, src_val[i], move_if_possible)
		end
		
		return dst_val
	end
	
	if src_type.base == "struct"
	then
		local dst_val = StructValue:new()
		
		for k,src_pair in pairs(src_val)
		do
			local src_elem_type, src_elem = table.unpack(src_pair)
			local dst_elem_type = src_elem_type
			
			dst_val[k] = {
				dst_elem_type,
				_make_value_from_value(context, dst_elem_type, src_elem_type, src_elem, move_if_possible)
			}
		end
		
		return dst_val
	end
	
	if dst_type.int_mask ~= nil and (src_type.int_mask == nil or src_type.int_mask ~= dst_type.int_mask)
	then
		return PlainValue:new(src_val:get() & dst_type.int_mask)
	end
	
	if move_if_possible
	then
		return src_val
	else
		return PlainValue:new(src_val:get())
	end
end

local _builtin_type_int8    = { rehex_type_le = "s8",    rehex_type_be = "s8",    length = 1, base = "number", string_fmt = "i1", type_key = {}, int_mask = 0xFF }
local _builtin_type_uint8   = { rehex_type_le = "u8",    rehex_type_be = "u8",    length = 1, base = "number", string_fmt = "I1", type_key = {}, int_mask = 0xFF }
local _builtin_type_int16   = { rehex_type_le = "s16le", rehex_type_be = "s16be", length = 2, base = "number", string_fmt = "i2", type_key = {}, int_mask = 0xFFFF }
local _builtin_type_uint16  = { rehex_type_le = "u16le", rehex_type_be = "u16be", length = 2, base = "number", string_fmt = "I2", type_key = {}, int_mask = 0xFFFF }
local _builtin_type_int32   = { rehex_type_le = "s32le", rehex_type_be = "s32be", length = 4, base = "number", string_fmt = "i4", type_key = {}, int_mask = 0xFFFFFFFF }
local _builtin_type_uint32  = { rehex_type_le = "u32le", rehex_type_be = "u32be", length = 4, base = "number", string_fmt = "I4", type_key = {}, int_mask = 0xFFFFFFFF }
local _builtin_type_int64   = { rehex_type_le = "s64le", rehex_type_be = "s64be", length = 8, base = "number", string_fmt = "i8", type_key = {}, int_mask = 0xFFFFFFFFFFFFFFFF }
local _builtin_type_uint64  = { rehex_type_le = "u64le", rehex_type_be = "u64be", length = 8, base = "number", string_fmt = "I8", type_key = {}, int_mask = 0xFFFFFFFFFFFFFFFF }
local _builtin_type_float32 = { rehex_type_le = "f32le", rehex_type_be = "f32be", length = 4, base = "number", string_fmt = "f",  type_key = {} }
local _builtin_type_float64 = { rehex_type_le = "f64le", rehex_type_be = "f64be", length = 8, base = "number", string_fmt = "d",  type_key = {} }

_builtin_type_int8  .signed_overlay   = _builtin_type_int8
_builtin_type_int8  .unsigned_overlay = _builtin_type_uint8
_builtin_type_uint8 .signed_overlay   = _builtin_type_int8
_builtin_type_uint8 .unsigned_overlay = _builtin_type_uint8

_builtin_type_int16  .signed_overlay   = _builtin_type_int16
_builtin_type_int16  .unsigned_overlay = _builtin_type_uint16
_builtin_type_uint16 .signed_overlay   = _builtin_type_int16
_builtin_type_uint16 .unsigned_overlay = _builtin_type_uint16

_builtin_type_int32  .signed_overlay   = _builtin_type_int32
_builtin_type_int32  .unsigned_overlay = _builtin_type_uint32
_builtin_type_uint32 .signed_overlay   = _builtin_type_int32
_builtin_type_uint32 .unsigned_overlay = _builtin_type_uint32

_builtin_type_int64  .signed_overlay   = _builtin_type_int64
_builtin_type_int64  .unsigned_overlay = _builtin_type_uint64
_builtin_type_uint64 .signed_overlay   = _builtin_type_int64
_builtin_type_uint64 .unsigned_overlay = _builtin_type_uint64

_builtin_types = {
	char   = _make_named_type("char",   _builtin_type_int8),
	int8_t = _make_named_type("int8_t", _builtin_type_int8),
	
	uint8_t = _make_named_type("uint8_t", _builtin_type_uint8),
	
	int16_t  = _make_named_type("int16_t",  _builtin_type_int16),
	uint16_t = _make_named_type("uint16_t", _builtin_type_uint16),
	
	int     = _make_named_type("int",     _builtin_type_int32),
	int32_t = _make_named_type("int32_t", _builtin_type_int32),
	
	uint32_t = _make_named_type("uint32_t", _builtin_type_uint32),
	
	int64_t = _make_named_type("int64_t", _builtin_type_int64),
	
	uint64_t = _make_named_type("uint64_t", _builtin_type_uint64),
	
	float = _make_named_type("float", _builtin_type_float32),
	
	double = _make_named_type("double", _builtin_type_float64),
	
	string = { name = "string", base = "string" },
}

local _builtin_variables = {
	["true"]  = { _builtin_types.int, ImmediateValue:new(1) },
	["false"] = { _builtin_types.int, ImmediateValue:new(0) },
}

local function _builtin_function_BigEndian(context, argv)
	context.big_endian = true
end

local function _builtin_function_LittleEndian(context, argv)
	context.big_endian = false
end

local function _builtin_function_IsBigEndian(context, argv)
	return _builtin_types.int, ImmediateValue:new(context.big_endian and 1 or 0)
end

local function _builtin_function_IsLittleEndian(context, argv)
	return _builtin_types.int, ImmediateValue:new(context.big_endian and 0 or 1)
end

local function _builtin_function_FEof(context, argv)
	return _builtin_types.int, ImmediateValue:new(context.next_variable >= context.interface.file_length() and 1 or 0)
end

local function _builtin_function_FileSize(context, argv)
	return _builtin_types.int64_t, ImmediateValue:new(context.interface.file_length())
end

local function _builtin_function_FSeek(context, argv)
	local seek_to = argv[1][2]:get()
	
	if seek_to < 0 or seek_to > context.interface.file_length()
	then
		return _builtin_types.int, ImmediateValue:new(-1)
	end
	
	context.next_variable = seek_to
	return _builtin_types.int, ImmediateValue:new(0)
end

local function _builtin_function_FSkip(context, argv)
	local seek_to = context.next_variable + argv[1][2]:get()
	
	if seek_to < 0 or seek_to > context.interface.file_length()
	then
		return _builtin_types.int, ImmediateValue:new(-1)
	end
	
	context.next_variable = seek_to
	return _builtin_types.int, ImmediateValue:new(0)
end

local function _builtin_function_FTell(context, argv)
	return _builtin_types.int64_t, ImmediateValue:new(context.next_variable)
end

local function _builtin_function_Printf(context, argv)
	-- Copy format unchanged
	local print_args = { argv[1][2]:get() }
	
	-- Pass value part of other arguments - should all be lua numbers or strings
	for i = 2, #argv
	do
		print_args[i] = argv[i][2]:get()
	end
	
	context.interface.print(string.format(table.unpack(print_args)))
end

local function _builtin_function_defn_ReadXXX(type_info, name)
	local impl = function(context, argv)
		local pos = argv[1][2]:get()
		
		if pos < 0 or (pos + type_info.length) > context.interface.file_length()
		then
			_template_error(context, "Attempt to read past end of file in " .. name .. " function")
		end
		
		local fmt = (context.big_endian and ">" or "<") .. type_info.string_fmt
		return type_info, FileValue:new(context, pos, type_info.length, fmt)
	end
	
	return {
		arguments = { _builtin_types.int64_t },
		defaults  = {
			-- FTell()
			{ debug.getinfo(1,'S').source, debug.getinfo(1, 'l').currentline, "call", "FTell", {} }
		},
		impl = impl,
	}
end

local function _builtin_function_ArrayLength(context, argv)
	if #argv ~= 1 or argv[1][1] == nil or not argv[1][1].is_array
	then
		local got_types = table.concat(_map(argv, function(v) return _get_type_name(v[1]) end), ", ")
		_template_error(context, "Attempt to call function ArrayLength(<any array type>) with incompatible argument types (" .. got_types .. ")")
	end
	
	return _builtin_types.int, ImmediateValue:new(#(argv[1][2]))
end

local function _resize_array(context, array_type, array_value, new_length)
	local data_start, data_end = array_value:data_range()
	if data_start ~= nil
	then
		if new_length < #array_value
		then
			_template_error(context, "Invalid attempt to shrink non-local array")
		end
		
		if data_end ~= context.next_variable
		then
			_template_error(context, "Invalid attempt to grow non-local array after declaring other variables")
		end
	end
	
	if new_length < 0
	then
		_template_error(context, "Invalid array length (" .. new_length .. ")")
	end
	
	if array_value.resize ~= nil
	then
		local old_length = #array_value
		
		array_value:resize(new_length)
		context.next_variable = data_start + (new_length * array_type.length)
	else
		local was_declaring_local_var = context.declaring_local_var
		context.declaring_local_var = (data_start == nil)
		
		if #array_value < new_length
		then
			local element_type = _make_nonarray_type(array_type)
			
			for i = #array_value, new_length - 1
			do
				table.insert(array_value, expand_value(context, element_type, nil, true)) -- TODO: struct_args
				context.interface.yield()
			end
		end
		
		for i = #array_value, new_length + 1, -1
		do
			table.remove(array_value)
		end
		
		context.declaring_local_var = was_declaring_local_var
	end
end

local function _builtin_function_ArrayResize(context, argv)
	if #argv ~= 2 or argv[1][1] == nil or not argv[1][1].is_array or not _type_is_number(argv[2][1])
	then
		local got_types = table.concat(_map(argv, function(v) return _get_type_name(v[1]) end), ", ")
		_template_error(context, "Attempt to call function ArrayResize(<any array type>, <number>) with incompatible argument types (" .. got_types .. ")")
	end
	
	local array_type = argv[1][1]
	local array_value = argv[1][2]
	
	local new_length = argv[2][2]:get()
	
	if array_type.is_const
	then
		_template_error(context, "Attempt to modify 'const' array")
	end
	
	_resize_array(context, array_type, array_value, new_length)
end

local function _builtin_function_ArrayExtend(context, argv)
	if #argv < 1 or #argv > 2 or argv[1][1] == nil or not argv[1][1].is_array or (#argv >= 2 and not _type_is_number(argv[2][1]))
	then
		local got_types = table.concat(_map(argv, function(v) return _get_type_name(v[1]) end), ", ")
		_template_error(context, "Attempt to call function ArrayExtend(<any array type>, <number>) with incompatible argument types (" .. got_types .. ")")
	end
	
	local array_type = argv[1][1]
	local array_value = argv[1][2]
	
	local rel_length = #argv >= 2 and argv[2][2]:get() or 1
	local new_length = #array_value + rel_length
	
	if array_type.is_const
	then
		_template_error(context, "Attempt to modify 'const' array")
	end
	
	_resize_array(context, array_type, array_value, new_length)
end

-- Table of builtin functions - gets copied into new interpreter contexts
--
-- Each key is a function name, the value is a table with the following values:
--
-- Table of argument types (arguments)
-- Table of default argument expressions (defaults)
-- Function implementation (impl)

local _builtin_functions = {
	BigEndian      = { arguments = {}, defaults = {}, impl = _builtin_function_BigEndian },
	LittleEndian   = { arguments = {}, defaults = {}, impl = _builtin_function_LittleEndian },
	IsBigEndian    = { arguments = {}, defaults = {}, impl = _builtin_function_IsBigEndian },
	IsLittleEndian = { arguments = {}, defaults = {}, impl = _builtin_function_IsLittleEndian },
	
	FEof     = { arguments = {},                       defaults = {}, impl = _builtin_function_FEof },
	FileSize = { arguments = {},                       defaults = {}, impl = _builtin_function_FileSize },
	FSeek    = { arguments = { _builtin_types.int64_t }, defaults = {}, impl = _builtin_function_FSeek },
	FSkip    = { arguments = { _builtin_types.int64_t }, defaults = {}, impl = _builtin_function_FSkip },
	FTell    = { arguments = {},                       defaults = {}, impl = _builtin_function_FTell },
	
	ReadI8  = _builtin_function_defn_ReadXXX(_builtin_types.int8_t,   "ReadI8"),
	ReadU8  = _builtin_function_defn_ReadXXX(_builtin_types.uint8_t,  "ReadU8"),
	ReadI16 = _builtin_function_defn_ReadXXX(_builtin_types.int16_t,  "ReadI16"),
	ReadU16 = _builtin_function_defn_ReadXXX(_builtin_types.uint16_t, "ReadU16"),
	ReadI32 = _builtin_function_defn_ReadXXX(_builtin_types.int32_t,  "ReadI32"),
	ReadU32 = _builtin_function_defn_ReadXXX(_builtin_types.uint32_t, "ReadU32"),
	ReadI64 = _builtin_function_defn_ReadXXX(_builtin_types.int64_t,  "ReadI64"),
	ReadU64 = _builtin_function_defn_ReadXXX(_builtin_types.uint64_t, "ReadU64"),
	
	ReadDouble = _builtin_function_defn_ReadXXX(_builtin_types.double, "ReadDouble"),
	ReadFloat  = _builtin_function_defn_ReadXXX(_builtin_types.float,  "ReadFloat"),
	
	Printf = { arguments = { _builtin_types.string, _variadic_placeholder }, defaults = {}, impl = _builtin_function_Printf },
	
	ArrayLength = { arguments = { _variadic_placeholder }, defaults = {}, impl = _builtin_function_ArrayLength },
	ArrayResize = { arguments = { _variadic_placeholder }, defaults = {}, impl = _builtin_function_ArrayResize },
	ArrayExtend = { arguments = { _variadic_placeholder }, defaults = {}, impl = _builtin_function_ArrayExtend },
}

_find_type = function(context, type_name)
	local convert = nil
	
	type_name = " " .. type_name .. " "
	
	local make_unsigned = false
	local make_signed = false
	local make_ref = false
	local make_const = false
	local make_array = false
	
	if type_name:find(" unsigned ") ~= nil
	then
		make_unsigned = true
		type_name = type_name:gsub(" unsigned ", " ", 1)
	elseif type_name:find(" signed ") ~= nil
	then
		make_signed = true
		type_name = type_name:gsub(" signed ", " ", 1)
	end
	
	if type_name:find(" & ") ~= nil
	then
		make_ref = true
		type_name = type_name:gsub(" & ", " ", 1)
	end
	
	if type_name:find(" const ") ~= nil
	then
		make_const = true
		type_name = type_name:gsub(" const ", " ", 1)
	end
	
	if type_name:find(" %[%] ") ~= nil
	then
		make_array = true
		type_name = type_name:gsub(" %[%] ", " ", 1)
	end
	
	type_name = type_name:sub(2, -2)
	
	local type_info = nil
	
	for i = #context.stack, 1, -1
	do
		for k, v in pairs(context.stack[i].var_types)
		do
			if k == type_name
			then
				type_info = v
				break
			end
		end
		
		if type_info
		then
			break
		end
	end
	
	if type_info ~= nil
	then
		if make_unsigned then type_info = _make_unsigned_type(context, type_info) end
		if make_signed   then type_info = _make_signed_type(context, type_info)   end
		if make_ref      then type_info = _make_ref_type(type_info)      end
		if make_const    then type_info = _make_const_type(type_info)    end
		if make_array    then type_info = _make_aray_type(type_info)     end
	end
	
	return type_info
end

--
-- The _eval_XXX functions are what actually take the individual statements
-- from the AST and execute them.
--
-- All _eval_XXX functions take the context and a single statement and return
-- the type and value of their result (or nothing if void).
--
-- Most _eval_XXX functions are called indirectly via the _eval_statement()
-- function and the _ops table.
---

_eval_number = function(context, statement)
	return _make_const_type(_builtin_types.int), ImmediateValue:new(statement[4])
end

_eval_string = function(context, statement)
	return _make_const_type(_builtin_types.string), ImmediateValue:new(statement[4])
end

-- Resolves a variable reference to an actual value.
_eval_ref = function(context, statement)
	local path = statement[4]
	
	-- This function walks along from the second element of path, resolving any array and/or
	-- struct dereferences before returning the final type+value pair.
	
	local _walk_path = function(rvalue)
		local rv_type = rvalue[1]
		local rv_val  = rvalue[2]
		
		local force_const = rv_type.is_const
		
		for i = 2, #path
		do
			if type(path[i]) == "table"
			then
				-- This is a statement to be evalulated and used as an array index.
				
				local array_idx_t, array_idx_v = _eval_statement(context, path[i])
				
				if array_idx_t == nil or array_idx_t.base ~= "number"
				then
					_template_error(context, "Invalid '" .. _get_type_name(array_idx_t) .. "' operand to '[]' operator - expected a number")
				end
				
				if rv_type.is_array
				then
					local array_idx = array_idx_v:get();
					
					if array_idx < 0 or array_idx >= #rv_val
					then
						_template_error(context, "Attempt to access out-of-range array index " .. array_idx)
					else
						rv_type = _make_nonarray_type(rv_type)
						rv_val = rv_val[array_idx_v:get() + 1]
					end
				else
					_template_error(context, "Attempt to access non-array variable as array")
				end
			else
				-- This is a string to be used as a struct member
				
				local member = path[i]
				
				if rv_type.base ~= "struct"
				then
					_template_error(context, "Attempt to access '" .. _get_type_name(rv_type) .. "' as a struct")
				end
				
				if rv_val[member] == nil
				then
					_template_error(context, "Attempt to access undefined struct member '" .. member .. "'")
				end
				
				rv_type = rv_val[member][1]
				rv_val  = rv_val[member][2]
			end
			
			force_const = force_const or rv_type.is_const
		end
		
		if force_const
		then
			rv_type = _make_const_type(rv_type)
		end
		
		return rv_type, rv_val
	end
	
	-- Walk through symbol tables looking for the first element in path
	
	for frame_idx = #context.stack, 1, -1
	do
		local frame = context.stack[frame_idx]
		
		if frame.vars[ path[1] ] ~= nil
		then
			return _walk_path(frame.vars[ path[1] ])
		end
		
		if frame.frame_type == FRAME_TYPE_FUNCTION or frame.frame_type == FRAME_TYPE_STRUCT
		then
			-- Don't look for variables in parent functions
			break
		end
	end
	
	if context.global_vars[ path[1] ] ~= nil
	then
		return _walk_path(context.global_vars[ path[1] ])
	end
	
	_template_error(context, "Attempt to use undefined variable '" .. path[1] .. "'")
end

_eval_add = function(context, statement)
	local v1_t, v1_v = _eval_statement(context, statement[4])
	local v2_t, v2_v = _eval_statement(context, statement[5])
	
	if _type_is_number(v1_t) and _type_is_number(v2_t)
	then
		return v1_t, ImmediateValue:new(v1_v:get() + v2_v:get())
	elseif _type_is_stringish(v1_t) and _type_is_stringish(v2_t)
	then
		local v1_s = _stringify_value(v1_t, v1_v)
		local v2_s = _stringify_value(v2_t, v2_v)
		
		return _builtin_types.string, ImmediateValue:new(v1_s .. v2_s)
	else
		_template_error(context, "Invalid operands to '+' operator - '" .. _get_type_name(v1_t) .. "' and '" .. _get_type_name(v2_t) .. "'")
	end
end

_numeric_op_func = function(func, sym)
	return function(context, statement)
		local v1_t, v1_v = _eval_statement(context, statement[4])
		local v2_t, v2_v = _eval_statement(context, statement[5])
		
		if (v1_t and v1_t.base) ~= "number" or (v2_t and v2_t.base) ~= "number"
		then
			_template_error(context, "Invalid operands to '" .. sym .. "' operator - '" .. _get_type_name(v1_t) .. "' and '" .. _get_type_name(v2_t) .. "'")
		end
		
		return v1_t, ImmediateValue:new(func(v1_v:get(), v2_v:get()))
	end
end

_eval_equal = function(context, statement)
	local v1_t, v1_v = _eval_statement(context, statement[4])
	local v2_t, v2_v = _eval_statement(context, statement[5])
	
	if _type_is_number(v1_t) and _type_is_number(v2_t)
	then
		local v1_n = v1_v:get()
		local v2_n = v2_v:get()
		
		return _builtin_types.int, ImmediateValue:new(v1_n == v2_n and 1 or 0)
	elseif _type_is_stringish(v1_t) and _type_is_stringish(v2_t)
	then
		local v1_s = _stringify_value(v1_t, v1_v)
		local v2_s = _stringify_value(v2_t, v2_v)
		
		return _builtin_types.int, ImmediateValue:new(v1_s == v2_s and 1 or 0)
	else
		_template_error(context, "Invalid operands to '==' operator - '" .. _get_type_name(v1_t) .. "' and '" .. _get_type_name(v2_t) .. "'")
	end
end

_eval_not_equal = function(context, statement)
	local v1_t, v1_v = _eval_statement(context, statement[4])
	local v2_t, v2_v = _eval_statement(context, statement[5])
	
	if _type_is_number(v1_t) and _type_is_number(v2_t)
	then
		local v1_n = v1_v:get()
		local v2_n = v2_v:get()
		
		return _builtin_types.int, ImmediateValue:new(v1_n ~= v2_n and 1 or 0)
	elseif _type_is_stringish(v1_t) and _type_is_stringish(v2_t)
	then
		local v1_s = _stringify_value(v1_t, v1_v)
		local v2_s = _stringify_value(v2_t, v2_v)
		
		return _builtin_types.int, ImmediateValue:new(v1_s ~= v2_s and 1 or 0)
	else
		_template_error(context, "Invalid operands to '!=' operator - '" .. _get_type_name(v1_t) .. "' and '" .. _get_type_name(v2_t) .. "'")
	end
end

_eval_bitwise_not = function(context, statement)
	local operand_t, operand_v = _eval_statement(context, statement[4])
	
	if operand_t == nil or operand_t.base ~= "number"
	then
		_template_error(context, "Invalid operand to '~' operator - expected numeric, got '" .. _get_type_name(operand_t) .. "'")
	end
	
	return operand_t, ImmediateValue:new(~operand_v:get())
end

_eval_logical_not = function(context, statement)
	local operand_t, operand_v = _eval_statement(context, statement[4])
	
	if operand_t == nil or operand_t.base ~= "number"
	then
		_template_error(context, "Invalid operand to '!' operator - expected numeric, got '" .. _get_type_name(operand_t) .. "'")
	end
	
	return _builtin_types.int, ImmediateValue:new(operand_v:get() == 0 and 1 or 0)
end

_eval_logical_and = function(context, statement)
	local v1_t, v1_v = _eval_statement(context, statement[4])
	
	if v1_t == nil or v1_t.base ~= "number"
	then
		_template_error(context, "Invalid left operand to '&&' operator - expected numeric, got '" .. _get_type_name(v1_t) .. "'")
	end
	
	if v1_v:get() == 0
	then
		return _builtin_types.int, ImmediateValue:new(0)
	end
	
	local v2_t, v2_v = _eval_statement(context, statement[5])
	
	if v2_t == nil or v2_t.base ~= "number"
	then
		_template_error(context, "Invalid right operand to '&&' operator - expected numeric, got '" .. _get_type_name(v2_t) .. "'")
	end
	
	if v2_v:get() == 0
	then
		return _builtin_types.int, ImmediateValue:new(0)
	end
	
	return _builtin_types.int, ImmediateValue:new(1)
end

_eval_logical_or = function(context, statement)
	local v1_t, v1_v = _eval_statement(context, statement[4])
	
	if v1_t == nil or v1_t.base ~= "number"
	then
		_template_error(context, "Invalid left operand to '||' operator - expected numeric, got '" .. _get_type_name(v1_t) .. "'")
	end
	
	if v1_v:get() ~= 0
	then
		return _builtin_types.int, ImmediateValue:new(1)
	end
	
	local v2_t, v2_v = _eval_statement(context, statement[5])
	
	if v2_t == nil or v2_t.base ~= "number"
	then
		_template_error(context, "Invalid right operand to '||' operator - expected numeric, got '" .. _get_type_name(v2_t) .. "'")
	end
	
	if v2_v:get() ~= 0
	then
		return _builtin_types.int, ImmediateValue:new(1)
	end
	
	return _builtin_types.int, ImmediateValue:new(0)
end

_eval_postfix_increment = function(context, statement)
	local value = statement[4]
	
	local value_t, value_v = _eval_statement(context, value)
	if value_t == nil or value_t.base ~= "number"
	then
		_template_error(context, "Invalid operand to postfix '++' operator - expected numeric, got '" .. _get_type_name(value_t) .. "'")
	end
	
	local old_value = value_v:get()
	
	local new_value = old_value + 1
	
	if value_t.int_mask ~= nil
	then
		new_value = new_value & value_t.int_mask
	end
	
	value_v:set(new_value)
	return value_t, ImmediateValue:new(old_value)
end

_eval_postfix_decrement = function(context, statement)
	local value = statement[4]
	
	local value_t, value_v = _eval_statement(context, value)
	if value_t == nil or value_t.base ~= "number"
	then
		_template_error(context, "Invalid operand to postfix '--' operator - expected numeric, got '" .. _get_type_name(value_t) .. "'")
	end
	
	local old_value = value_v:get()
	
	local new_value = old_value - 1
	
	if value_t.int_mask ~= nil
	then
		new_value = new_value & value_t.int_mask
	end
	
	value_v:set(new_value)
	return value_t, ImmediateValue:new(old_value)
end

_eval_unary_plus = function(context, statement)
	local value = statement[4]
	
	local value_t, value_v = _eval_statement(context, value)
	if value_t == nil or value_t.base ~= "number"
	then
		_template_error(context, "Invalid operand to unary '+' operator - expected numeric, got '" .. _get_type_name(value_t) .. "'")
	end
	
	return value_t, ImmediateValue:new(value_v:get())
end

_eval_unary_minus = function(context, statement)
	local value = statement[4]
	
	local value_t, value_v = _eval_statement(context, value)
	if value_t == nil or value_t.base ~= "number"
	then
		_template_error(context, "Invalid operand to unary '-' operator - expected numeric, got '" .. _get_type_name(value_t) .. "'")
	end
	
	return value_t, ImmediateValue:new(-1 * value_v:get())
end

expand_value = function(context, type_info, struct_args, is_array_element)
	if type_info.base == "struct"
	then
		local struct_arg_values = {}
		local args_ok = true
		
		if struct_args ~= nil
		then
			for i = 1, #struct_args
			do
				struct_arg_values[i] = { _eval_statement(context, struct_args[i]) }
			end
		end
		
		for i = 1, math.max(#struct_arg_values, #type_info.arguments)
		do
			if i > #struct_arg_values or i > #type_info.arguments
			then
				args_ok = false
			else
				local dst_type = type_info.arguments[i][2]
				local got_type = struct_arg_values[i][1]
				
				if dst_type.is_ref
				then
					if dst_type.type_key ~= got_type.type_key
						or ((not got_type.is_array) ~= (not dst_type.is_array))
						or (got_type.is_const and not dst_type.is_const)
					then
						args_ok = false
					end
				else
					if not _type_assignable(dst_type, struct_arg_values[i][1])
					then
						args_ok = false
					end
				end
			end
		end
		
		if not args_ok
		then
			local got_types = table.concat(_map(struct_arg_values, function(v) return _get_type_name(v[1]) end), ", ")
			local expected_types = table.concat(_map(type_info.arguments, function(v) return _get_type_name(v[2]) end), ", ")
			
			_template_error(context, "Attempt to declare struct type '" .. _get_type_name(type_info) .. "' with incompatible argument types (" .. got_types .. ") - expected (" .. expected_types .. ")")
		end
		
		for i = 1, #struct_arg_values
		do
			local dst_type = type_info.arguments[i][2]
			
			if dst_type.is_ref
			then
				struct_arg_values[i] = { dst_type, struct_arg_values[i][2] }
			else
				struct_arg_values[i] = { dst_type, _make_value_from_value(context, dst_type, struct_arg_values[i][1], struct_arg_values[i][2], false) }
			end
		end
		
		local members = StructValue:new()
		
		local frame = {
			frame_type = FRAME_TYPE_STRUCT,
			var_types = {},
			vars = {},
			struct_members = members,
			
			blocks_flowctrl_types = (FLOWCTRL_TYPE_RETURN | FLOWCTRL_TYPE_BREAK | FLOWCTRL_TYPE_CONTINUE),
		}
		
		for idx, arg in ipairs(type_info.arguments)
		do
			local arg_name = arg[1]
			frame.vars[arg_name] = struct_arg_values[idx]
		end
		
		table.insert(context.stack, frame)
		_exec_statements(context, type_info.code)
		table.remove(context.stack)
		
		return members
	else
		if context.declaring_local_var
		then
			if type_info.base == "number"
			then
				return PlainValue:new(0)
			elseif type_info.base == "string"
			then
				return PlainValue:new("")
			else
				error("Internal error: Unexpected base type '" .. type_info.base .. "' at " .. filename .. ":" .. line_num)
			end
		else
			if (context.next_variable + type_info.length) > context.interface:file_length()
			then
				_template_error(context, "Hit end of file when declaring variable")
			end
			
			local base_off = context.next_variable
			context.next_variable = base_off + type_info.length
			
			local data_type_fmt = (context.big_endian and ">" or "<") .. type_info.string_fmt
			return FileValue:new(context, base_off, type_info.length, data_type_fmt)
		end
	end
end

local function _decl_variable(context, statement, var_type, var_name, struct_args, array_size, initial_value, is_local)
	local filename = statement[1]
	local line_num = statement[2]
	
	local iv_type, iv_value
	if initial_value ~= nil
	then
		iv_type, iv_value = _eval_statement(context, initial_value)
	end
	
	local type_info
	if type(var_type) == "table"
	then
		type_info = var_type
	else
		type_info = _find_type(context, var_type)
		if type_info == nil
		then
			_template_error(context, "Unknown variable type '" .. var_type .. "'")
		end
	end
	
	if struct_args ~= nil and type_info.base ~= "struct"
	then
		_template_error(context, "Variable declaration with parameters for non-struct type '" .. _get_type_name(type_info) .. "'")
	end
	
	if type_info.array_size ~= nil
	then
		if array_size ~= nil
		then
			_template_error(context, "Multidimensional arrays are not supported")
		end
		
		-- Filthy filthy filthy...
		array_size = { debug.getinfo(1,'S').source, debug.getinfo(1, 'l').currentline, "num", type_info.array_size }
	end
	
	local dest_tables
	
	if not is_local and _can_do_flowctrl_here(context, FLOWCTRL_TYPE_RETURN)
	then
		_template_error(context, "Attempt to declare non-local variable inside function")
	end
	
	local struct_frame = _topmost_frame_of_type(context, FRAME_TYPE_STRUCT)
	if struct_frame ~= nil and not is_local
	then
		dest_tables = { struct_frame.vars, struct_frame.struct_members }
		
		if struct_frame.vars[var_name] ~= nil
		then
			_template_error(context, "Attempt to redefine struct member '" .. var_name .. "'")
		end
	elseif is_local
	then
		dest_tables = { context.stack[#context.stack].vars }
	else
		dest_tables = { context.global_vars }
	end
	
	if dest_tables[1][var_name] ~= nil
	then
		_template_error(context, "Attempt to redefine variable '" .. var_name .. "'")
	end
	
	if type_info.is_ref
	then
		if not is_local
		then
			_template_error(context, "Attempt to define non-local reference '" .. var_name .. "'")
		end
		
		if initial_value == nil
		then
			_template_error(context, "Attempt to define uninitialised reference '" .. var_name .. "'")
		end
		
		if iv_type == nil
			or type_info.type_key ~= iv_type.type_key
			or ((not type_info.is_const) and iv_type.is_const)
		then
			_template_error(context, "can't assign '" .. _get_type_name(iv_type) .. "' to type '" .. _get_type_name(type_info) .. "'")
		end
		
		for _,t in ipairs(dest_tables)
		do
			t[var_name] = { type_info, iv_value }
		end
		
		return
	end
	
	if context.big_endian
	then
		type_info = _make_overlay_type(type_info, { big_endian = true,  rehex_type = type_info.rehex_type_be })
	else
		type_info = _make_overlay_type(type_info, { big_endian = false, rehex_type = type_info.rehex_type_le })
	end
	
	local root_value
	
	if array_size == nil
	then
		local base_off = context.next_variable
		
		root_value = expand_value(context, type_info, struct_args, false)
		
		for _,t in ipairs(dest_tables)
		do
			t[var_name] = { type_info, root_value }
		end
	else
		local ArrayLength_type, ArrayLength_val = _eval_statement(context, array_size)
		if ArrayLength_type == nil or ArrayLength_type.base ~= "number"
		then
			_template_error(context, "Expected numeric type for array size, got '" .. _get_type_name(ArrayLength_type) .. "'")
		end
		
		local array_type_info = _make_aray_type(type_info)
		
		if type_info.base ~= "struct" and not context.declaring_local_var
		then
			local data_type_fmt = (context.big_endian and ">" or "<") .. type_info.string_fmt
			root_value = FileArrayValue:new(context, context.next_variable, ArrayLength_val:get(), type_info.length, data_type_fmt)
			
			context.next_variable = context.next_variable + (ArrayLength_val:get() * type_info.length)
			
			for _,t in ipairs(dest_tables)
			do
				t[var_name] = {
					array_type_info,
					root_value
				}
			end
		else
			root_value = ArrayValue:new()
			
			if not context.declaring_local_var
			then
				root_value.offset = context.next_variable
			end
			
			for _,t in ipairs(dest_tables)
			do
				t[var_name] = {
					array_type_info,
					root_value
				}
			end
			
			for i = 0, ArrayLength_val:get() - 1
			do
				local value = expand_value(context, type_info, struct_args, true)
				table.insert(root_value, value)
				
				context.interface.yield()
			end
		end
		
		type_info = array_type_info
	end
	
	if initial_value ~= nil
	then
		_assign_value(context, type_info, root_value, iv_type, iv_value)
	end
end

_eval_variable = function(context, statement)
	local var_type = statement[4]
	local var_name = statement[5]
	local struct_args = statement[6]
	local array_size = statement[7]
	
	_decl_variable(context, statement, var_type, var_name, struct_args, array_size, nil, false)
end

_eval_local_variable = function(context, statement)
	local var_type = statement[4]
	local var_name = statement[5]
	local struct_args = statement[6]
	local array_size = statement[7]
	local initial_value = statement[8]
	
	local was_declaring_local_var = context.declaring_local_var
	context.declaring_local_var = true
	
	_decl_variable(context, statement, var_type, var_name, struct_args, array_size, initial_value, true)
	
	context.declaring_local_var = was_declaring_local_var
end

_eval_assign = function(context, statement)
	local dst_expr = statement[4]
	local src_expr = statement[5]
	
	local dst_type, dst_val = _eval_statement(context, dst_expr)
	local src_type, src_val = _eval_statement(context, src_expr)
	
	if dst_type.is_const
	then
		_template_error(context, "Attempted modification of const type '" .. _get_type_name(dst_type) .. "'")
	end
	
	_assign_value(context, dst_type, dst_val, src_type, src_val)
	
	return dst_type, dst_val
end

_eval_call = function(context, statement)
	local func_name = statement[4]
	local func_args = statement[5]
	
	local func_defn = context.functions[func_name]
	if func_defn == nil
	then
		_template_error(context, "Attempt to call undefined function '" .. func_name .. "'")
	end
	
	local func_arg_values = {}
	local args_ok = true
	
	for i = 1, #func_args
	do
		func_arg_values[i] = { _eval_statement(context, func_args[i]) }
	end
	
	for i = #func_arg_values + 1, #func_defn.defaults
	do
		func_arg_values[i] = { _eval_statement(context, func_defn.defaults[i]) }
	end
	
	for i = 1, math.max(#func_arg_values, #func_defn.arguments)
	do
		if func_defn.arguments[i] == _variadic_placeholder
		then
			break
		end
		
		if i > #func_arg_values or i > #func_defn.arguments
		then
			args_ok = false
		else
			local dst_type = func_defn.arguments[i]
			local got_type = func_arg_values[i][1]
			
			if dst_type.is_ref
			then
				if dst_type.type_key ~= got_type.type_key
					or ((not got_type.is_array) ~= (not dst_type.is_array))
					or (got_type.is_const and not dst_type.is_const)
				then
					args_ok = false
				end
			else
				if not _type_assignable(dst_type, func_arg_values[i][1])
				then
					args_ok = false
				end
			end
		end
	end
	
	if not args_ok
	then
		local got_types = table.concat(_map(func_arg_values, function(v) return _get_type_name(v[1]) end), ", ")
		local expected_types = table.concat(_map(func_defn.arguments, function(v) return _get_type_name(v) end), ", ")
		
		_template_error(context, "Attempt to call function " .. func_name .. "(" .. expected_types .. ") with incompatible argument types (" .. got_types .. ")")
	end
	
	for i = 1, #func_arg_values
	do
		local dst_type = func_defn.arguments[i]
		
		if dst_type == _variadic_placeholder
		then
			break
		end
		
		if dst_type.is_ref
		then
			func_arg_values[i] = { dst_type, func_arg_values[i][2] }
		else
			func_arg_values[i] = { dst_type, _make_value_from_value(context, dst_type, func_arg_values[i][1], func_arg_values[i][2], false) }
		end
	end
	
	return func_defn.impl(context, func_arg_values)
end

_eval_return = function(context, statement)
	local retval = statement[4]
	
	if not _can_do_flowctrl_here(context, FLOWCTRL_TYPE_RETURN)
	then
		_template_error(context, "'return' statement not allowed here")
	end
	
	local func_frame = _topmost_frame_of_type(context, FRAME_TYPE_FUNCTION)
	
	if retval
	then
		local retval_t, retval_v = _eval_statement(context, retval)
		
		if not _type_assignable(func_frame.return_type, retval_t)
		then
			_template_error(context, "return operand type '" .. _get_type_name(retval_t) .. "' not compatible with function return type '" .. _get_type_name(func_frame.return_type) .. "'")
		end
		
		if retval_t
		then
			retval = { retval_t, retval_v }
		else
			retval = nil
		end
	elseif func_frame.return_type ~= nil
	then
		_template_error(context, "return without an operand in function that returns type '" .. _get_type_name(func_frame.return_type) .. "'")
	end
	
	return { flowctrl = FLOWCTRL_TYPE_RETURN }, retval
end

_eval_func_defn = function(context, statement)
	local func_ret_type   = statement[4]
	local func_name       = statement[5]
	local func_args       = statement[6]
	local func_statements = statement[7]
	
	if #context.stack > 1
	then
		_template_error(context, "Attempt to define function inside another block")
	end
	
	if context.functions[func_name] ~= nil
	then
		_template_error(context, "Attempt to redefine function '" .. func_name .. "'")
	end
	
	local ret_type
	if func_ret_type ~= "void"
	then
		ret_type = _find_type(context, func_ret_type)
		if ret_type == nil
		then
			_template_error(context, "Attempt to define function '" .. func_name .. "' with undefined return type '" .. func_ret_type .. "'")
		end
	end
	
	local arg_types = {}
	for i = 1, #func_args
	do
		local arg_type_name = func_args[i][1]
		
		local type_info = _find_type(context, arg_type_name)
		if type_info == nil
		then
			_template_error(context, "Attempt to define function '" .. func_name .. "' with undefined argument type '" .. arg_type_name .. "'")
		end
		
		table.insert(arg_types, type_info)
	end
	
	local impl_func = function(context, arguments)
		local frame = {
			frame_type = FRAME_TYPE_FUNCTION,
			var_types = {},
			vars = {},
			
			handles_flowctrl_types = FLOWCTRL_TYPE_RETURN,
			blocks_flowctrl_types  = (FLOWCTRL_TYPE_BREAK | FLOWCTRL_TYPE_CONTINUE),
			
			return_type = ret_type,
		}
		
		if #arguments ~= #func_args
		then
			error("Internal error: wrong number of function arguments")
		end
		
		for i = 1, #arguments
		do
			local arg_type = arg_types[i]
			local arg_name = func_args[i][2]
			
			if not _type_assignable(arg_type, arguments[i][1])
			then
				error("Internal error: incompatible function arguments")
			end
			
			frame.vars[arg_name] = arguments[i]
		end
		
		table.insert(context.stack, frame)
		
		local retval
		
		for _, statement in ipairs(func_statements)
		do
			local sr_t, sr_v = _eval_statement(context, statement)
			
			if sr_t and sr_t.flowctrl ~= nil
			then
				if sr_t.flowctrl == FLOWCTRL_TYPE_RETURN
				then
					retval = sr_v
					break
				else
					error("Internal error: unexpected flowctrl type '" .. sr_t.flowctrl .. "'")
				end
			end
		end
		
		table.remove(context.stack)
		
		if retval == nil and ret_type ~= nil
		then
			_template_error(context, "No return statement in function returning non-void")
		end
		
		if retval ~= nil
		then
			return table.unpack(retval)
		end
	end
	
	context.functions[func_name] = {
		arguments = arg_types,
		defaults  = {},
		impl      = impl_func,
	}
end

_eval_struct_defn = function(context, statement)
	local struct_name       = statement[4]
	local struct_args       = statement[5]
	local struct_statements = statement[6]
	local typedef_name      = statement[7]
	local var_decl          = statement[8]
	
	local struct_typename = struct_name ~= nil and "struct " .. struct_name or nil
	
	if struct_typename ~= nil and _find_type(context, struct_typename) ~= nil
	then
		_template_error(context, "Attempt to redefine type '" .. struct_typename .. "'")
	end
	
	if typedef_name ~= nil and _find_type(context, typedef_name) ~= nil
	then
		_template_error(context, "Attempt to redefine type '" .. typedef_name .. "'")
	end
	
	local args = {}
	for i = 1, #struct_args
	do
		local type_info = _find_type(context, struct_args[i][1])
		if type_info == nil
		then
			_template_error(context, "Attempt to define 'struct " .. struct_name .. "' with undefined argument type '" .. struct_args[i][1] .. "'")
		end
		
		table.insert(args, { struct_args[i][2], type_info })
	end
	
	local type_info = {
		base      = "struct",
		arguments = args,
		code      = struct_statements,
		
		struct_name = struct_name,
		type_key  = {}, -- Uniquely-identifiable table reference used to check if struct
		                  -- types are derived from the same root (and thus compatible)
		
		-- rehex_type_le = "s8",
		-- rehex_type_be = "s8",
		-- length = 1,
		-- string_fmt = "i1"
	}
	
	if struct_typename ~= nil
	then
		context.stack[#context.stack].var_types[struct_typename] = _make_named_type(struct_typename, type_info)
	end
	
	if typedef_name ~= nil
	then
		context.stack[#context.stack].var_types[typedef_name] = _make_named_type(typedef_name, type_info)
	end
	
	if var_decl ~= nil
	then
		local var_name   = var_decl[1]
		local var_args   = var_decl[2]
		local array_size = var_decl[3]
		
		_decl_variable(context, statement, type_info, var_name, var_args, array_size, nil, false)
	end
end

_eval_typedef = function(context, statement)
	local type_name    = statement[4]
	local typedef_name = statement[5]
	local array_size   = statement[6]
	
	local type_info = _find_type(context, type_name)
	if type_info == nil
	then
		_template_error(context, "Use of undefined type '" .. type_name .. "'")
	end
	
	if _find_type(context, typedef_name) ~= nil
	then
		_template_error(context, "Attempt to redefine type '" .. typedef_name .. "'")
	end
	
	if array_size ~= nil
	then
		if type_info.array_size ~= nil
		then
			_template_error(context, "Multidimensional arrays are not supported")
		end
		
		local ArrayLength_type, ArrayLength_val = _eval_statement(context, array_size)
		if ArrayLength_type == nil or ArrayLength_type.base ~= "number"
		then
			_template_error(context, "Expected numeric type for array size, got '" .. _get_type_name(ArrayLength_type) .. "'")
		end
		
		type_info = _make_aray_type(type_info)
		type_info.array_size = ArrayLength_val:get()
	end
	
	context.stack[#context.stack].var_types[typedef_name] = _make_named_type(typedef_name, type_info)
end

_eval_enum = function(context, statement)
	local type_name    = statement[4]
	local enum_name    = statement[5]
	local members      = statement[6]
	local typedef_name = statement[7]
	local var_decl     = statement[8]
	
	local enum_typename = enum_name ~= nil and "enum " .. enum_name or nil
	
	-- Check type names are valid
	
	local type_info = _find_type(context, type_name)
	if type_info == nil
	then
		_template_error(context, "Use of undefined type '" .. type_name .. "'")
	end
	
	if enum_typename ~= nil and _find_type(context, enum_typename) ~= nil
	then
		_template_error(context, "Attempt to redefine type '" .. enum_typename .. "'")
	end
	
	if typedef_name ~= nil and _find_type(context, typedef_name) ~= nil
	then
		_template_error(context, "Attempt to redefine type '" .. typedef_name .. "'")
	end
	
	-- Define each member as a const variable of the base type in the current scope.
	
	local next_member_val = 0
	local scope_vars = context.stack[#context.stack].vars
	
	for _, member_pair in pairs(members)
	do
		local member_name, member_expr = table.unpack(member_pair)
		
		if scope_vars[member_name] ~= nil
		then
			_template_error(context, "Attempt to redefine name '" .. member_name .. "'")
		end
		
		if member_expr ~= nil
		then
			local member_t, member_v = _eval_statement(context, member_expr)
			
			if member_t == nil or member_t.base ~= "number"
			then
				_template_error(context, "Invalid type '" .. _get_type_name(member_t) .. "' for enum member '" .. member_name .. "'", member_expr[1], member_expr[2])
			end
			
			next_member_val = member_v:get()
		end
		
		scope_vars[member_name] = { type_info, ImmediateValue:new(next_member_val) }
		next_member_val = next_member_val + 1
	end
	
	-- Define the enum type as a copy of its base type
	
	if enum_typename ~= nil
	then
		type_info = _make_named_type(enum_typename, type_info)
		context.stack[#context.stack].var_types[enum_typename] = type_info
	end
	
	if typedef_name ~= nil
	then
		context.stack[#context.stack].var_types[typedef_name] = _make_named_type(typedef_name, type_info)
	end
	
	if var_decl ~= nil
	then
		local var_name   = var_decl[1]
		local array_size = var_decl[3]
		
		_decl_variable(context, statement, type_info, var_name, nil, array_size, nil, false)
	end
end

_eval_if = function(context, statement)
	for i = 4, #statement
	do
		local cond = statement[i][2] and statement[i][1] or { "BUILTIN", 0, "num", 1 }
		local code = statement[i][2] or statement[i][1]
		
		local cond_t, cond_v = _eval_statement(context, cond)
		
		if (cond_t and cond_t.base) ~= "number"
		then
			_template_error(context, "Expected numeric expression to if/else if", cond[1], cond[2])
		end
		
		if cond_v:get() ~= 0
		then
			local frame = {
				frame_type = FRAME_TYPE_SCOPE,
				var_types = {},
				vars = {},
			}
			
			table.insert(context.stack, frame)
			
			for _, statement in ipairs(code)
			do
				local sr_t, sr_v = _eval_statement(context, statement)
				
				if sr_t and sr_t.flowctrl ~= nil
				then
					table.remove(context.stack)
					return sr_t, sr_v
				end
			end
			
			table.remove(context.stack)
			
			break
		end
	end
end

_eval_for = function(context, statement)
	local init_expr = statement[4]
	local cond_expr = statement[5]
	local iter_expr = statement[6]
	local body      = statement[7]
	
	local frame = {
		frame_type = FRAME_TYPE_SCOPE,
		var_types = {},
		vars = {},
		
		handles_flowctrl_types = (FLOWCTRL_TYPE_BREAK | FLOWCTRL_TYPE_CONTINUE),
	}
	
	table.insert(context.stack, frame)
	
	if init_expr
	then
		_eval_statement(context, init_expr)
	end
	
	while true
	do
		if cond_expr
		then
			local cond_t, cond_v = _eval_statement(context, cond_expr)
			
			if (cond_t and cond_t.base) ~= "number"
			then
				_template_error(context, "Unexpected type '" .. _get_type_name(cond_t) .. "' used as for loop condition", cond_expr[1], cond_expr[2])
			end
			
			if cond_v:get() == 0
			then
				break
			end
		else
			context.interface.yield()
		end
		
		-- Define another scope inside the loop's outer scope so any variables defined
		-- inside the loop are cleaned up on each iteration.
		
		local frame = {
			frame_type = FRAME_TYPE_SCOPE,
			var_types = {},
			vars = {},
		}
		
		table.insert(context.stack, frame)
		
		for _, statement in ipairs(body)
		do
			local sr_t, sr_v = _eval_statement(context, statement)
			
			if sr_t and sr_t.flowctrl ~= nil
			then
				if sr_t.flowctrl == FLOWCTRL_TYPE_BREAK
				then
					table.remove(context.stack)
					table.remove(context.stack)
					return
				elseif sr_t.flowctrl == FLOWCTRL_TYPE_CONTINUE
				then
					break
				else
					table.remove(context.stack)
					table.remove(context.stack)
					return sr_t, sr_v
				end
			end
		end
		
		table.remove(context.stack)
		
		if iter_expr
		then
			_eval_statement(context, iter_expr)
		end
	end
	
	table.remove(context.stack)
end

_eval_switch = function(context, statement)
	local expr = statement[4]
	local cases = statement[5]
	
	local expr_t, expr_v = _eval_statement(context, expr)
	
	if expr_t == nil or (expr_t.base ~= "number" and expr_t.base ~= "string")
	then
		_template_error(context, "Unexpected type '" .. _get_type_name(expr_t) .. "' passed to 'switch' statement (expected number or string)")
	end
	
	local found_match = false
	
	for _, case in ipairs(cases)
	do
		local case_expr = case[1]
		local case_body = case[2]
		
		if case_expr ~= nil
		then
			local case_expr_t, case_expr_v = _eval_statement(context, case_expr)
			
			if case_expr_t == nil or case_expr_t.base ~= expr_t.base
			then
				_template_error(context, "Unexpected type '" .. _get_type_name(case_expr_t) .. "' passed to 'case' statement (expected '" .. _get_type_name(expr_t) .. "')", case_expr[1], case_expr[2])
			end
			
			if expr_v:get() == case_expr_v:get()
			then
				case[1] = true
				found_match = true
			else
				case[1] = false
			end
		end
	end
	
	if not found_match
	then
		for _, case in ipairs(cases)
		do
			local case_expr = case[1]
			local case_body = case[2]
			
			if case_expr == nil
			then
				case[1] = true
			end
		end
	end
	
	local frame = {
		frame_type = FRAME_TYPE_SCOPE,
		var_types = {},
		vars = {},
		
		handles_flowctrl_types = FLOWCTRL_TYPE_BREAK,
	}
	
	table.insert(context.stack, frame)
	
	found_match = false
	
	for _, case in ipairs(cases)
	do
		local case_matched = case[1]
		local case_body = case[2]
		
		if not found_match and case_matched
		then
			found_match = true
		end
		
		if found_match
		then
			for _, statement in ipairs(case_body)
			do
				local sr_t, sr_v = _eval_statement(context, statement)
				
				if sr_t and sr_t.flowctrl ~= nil
				then
					if sr_t.flowctrl == FLOWCTRL_TYPE_BREAK
					then
						table.remove(context.stack)
						return
					else
						table.remove(context.stack)
						return sr_t, sr_v
					end
				end
			end
		end
	end
	
	table.remove(context.stack)
end

_eval_block = function(context, statement)
	local body = statement[4]
	
	local frame = {
		frame_type = FRAME_TYPE_SCOPE,
		var_types = {},
		vars = {},
	}
	
	table.insert(context.stack, frame)
	
	for _, statement in ipairs(body)
	do
		local sr_t, sr_v = _eval_statement(context, statement)
		
		if sr_t and sr_t.flowctrl ~= nil
		then
			table.remove(context.stack)
			return sr_t, sr_v
		end
	end
	
	table.remove(context.stack)
end

_eval_break = function(context, statement)
	if not _can_do_flowctrl_here(context, FLOWCTRL_TYPE_BREAK)
	then
		_template_error(context, "'break' statement not allowed here")
	end
	
	return { flowctrl = FLOWCTRL_TYPE_BREAK }, retval
end

_eval_continue = function(context, statement)
	if not _can_do_flowctrl_here(context, FLOWCTRL_TYPE_CONTINUE)
	then
		_template_error(context, "'continue' statement not allowed here")
	end
	
	return { flowctrl = FLOWCTRL_TYPE_CONTINUE }, retval
end

_eval_cast = function(context, statement)
	local type_name = statement[4]
	local value_expr = statement[5]
	
	local type_info = _find_type(context, type_name)
	if type_info == nil
	then
		_template_error(context, "Unknown type '" .. type_name .. "' used in cast")
	end
	
	local value_t, value_v = _eval_statement(context, value_expr)
	if not _type_assignable(type_info, value_t)
	then
		_template_error(context, "Invalid conversion from '" .. _get_type_name(value_t) .. "' to '" .. _get_type_name(type_info) .. "'")
	end
	
	if type_info.int_mask ~= nil
	then
		value_v = ImmediateValue:new(value_v:get() & type_info.int_mask)
	else
		_template_error(context, "Internal error: Unhandled cast from '" .. _get_type_name(value_t) .. "' to '" .. _get_type_name(type_info) .. "'")
	end
	
	return type_info, value_v
end

_eval_ternary = function(context, statement)
	local cond_expr     = statement[4]
	local if_true_expr  = statement[5]
	local if_false_expr = statement[6]
	
	local cond_t, cond_v = _eval_statement(context, cond_expr)
	if cond_t == nil or cond_t.base ~= "number"
	then
		_template_error(context, "Invalid condition operand to ternary operator - expected numeric, got '" .. _get_type_name(cond_t) .. "'")
	end
	
	if cond_v:get() ~= 0
	then
		-- Condition is true
		return _eval_statement(context, if_true_expr)
	else
		-- Condition is false
		return _eval_statement(context, if_false_expr)
	end
end

_eval_statement = function(context, statement)
	local filename = statement[1]
	local line_num = statement[2]
	
	context.interface.yield()
	
	local op = statement[3]
	
	if _ops[op] ~= nil
	then
		table.insert(context.st_stack, statement)
		local result = { _ops[op](context, statement) }
		table.remove(context.st_stack)
		
		return table.unpack(result);
	else
		error("Internal error: unexpected op '" .. op .. "' at " .. filename .. ":" .. line_num)
	end
	
end

_exec_statements = function(context, statements)
	for _, statement in ipairs(statements)
	do
		_eval_statement(context, statement)
	end
end

_ops = {
	num = _eval_number,
	str = _eval_string,
	ref = _eval_ref,
	
	["variable"]       = _eval_variable,
	["local-variable"] = _eval_local_variable,
	["assign"]         = _eval_assign,
	["call"]           = _eval_call,
	["return"]         = _eval_return,
	["function"]       = _eval_func_defn,
	["struct"]         = _eval_struct_defn,
	["typedef"]        = _eval_typedef,
	["enum"]           = _eval_enum,
	["if"]             = _eval_if,
	["for"]            = _eval_for,
	["switch"]         = _eval_switch,
	["block"]          = _eval_block,
	["break"]          = _eval_break,
	["continue"]       = _eval_continue,
	["cast"]           = _eval_cast,
	["ternary"]        = _eval_ternary,
	
	add      = _eval_add,
	subtract = _numeric_op_func(function(v1, v2) return v1 - v2 end, "-"),
	multiply = _numeric_op_func(function(v1, v2) return v1 * v2 end, "*"),
	divide   = _numeric_op_func(function(v1, v2) return v1 / v2 end, "/"),
	mod      = _numeric_op_func(function(v1, v2) return v1 % v2 end, "%"),
	
	["left-shift"]  = _numeric_op_func(function(v1, v2) return v1 << v2 end, "<<"),
	["right-shift"] = _numeric_op_func(function(v1, v2) return v1 >> v2 end, ">>"),
	
	["bitwise-not"] = _eval_bitwise_not,
	["bitwise-and"] = _numeric_op_func(function(v1, v2) return v1 & v2 end, "&"),
	["bitwise-xor"] = _numeric_op_func(function(v1, v2) return v1 ^ v2 end, "^"),
	["bitwise-or"]  = _numeric_op_func(function(v1, v2) return v1 | v2 end, "|"),
	
	["less-than"]             = _numeric_op_func(function(v1, v2) return v1 <  v2 and 1 or 0 end, "<"),
	["less-than-or-equal"]    = _numeric_op_func(function(v1, v2) return v1 <= v2 and 1 or 0 end, "<="),
	["greater-than"]          = _numeric_op_func(function(v1, v2) return v1 >  v2 and 1 or 0 end, ">"),
	["greater-than-or-equal"] = _numeric_op_func(function(v1, v2) return v1 >= v2 and 1 or 0 end, ">="),
	
	["equal"]     = _eval_equal,
	["not-equal"] = _eval_not_equal,
	
	["logical-not"] = _eval_logical_not,
	["logical-and"] = _eval_logical_and,
	["logical-or"]  = _eval_logical_or,
	
	["postfix-increment"] = _eval_postfix_increment,
	["postfix-decrement"] = _eval_postfix_decrement,
	
	["plus"]  = _eval_unary_plus,
	["minus"] = _eval_unary_minus,
}

--- External entry point into the interpreter
-- @function execute
--
-- @param interface Table of interface functions to be used by the interpreter.
-- @param statements AST table as returned by the parser.
--
-- The interface table must have the following functions:
--
-- interface.set_data_type(offset, length, data_type)
-- interface.set_comment(offset, length, comment_text)
--
-- Thin wrappers around the REHex APIs, to allow for testing.
--
-- interface.yield()
--
-- Periodically called by the executor to allow processing UI events.
-- An error() may be raised within to abort the interpreter.

local function execute(interface, statements)
	local context = {
		interface = interface,
		
		functions = {},
		stack = {},
		
		-- This table holds the top-level "global" (i.e. not "local") variables by name.
		-- Each element points to a tuple of { type, value } like other rvalues.
		global_vars = {},
		
		-- This table holds our current position in global_vars - under which new variables
		-- be added and relative to which any lookups should be performed.
		--
		-- Each key will either be a tuple of { key, table }, where the key is a string
		-- when we are descending into a struct member or a number where we are in an array
		-- and the table is a reference to the element in global_vars at this point.
		global_stack = {},
		
		next_variable = 0,
		
		-- Are we currently accessing variables from the file as big endian? Toggled by
		-- the built-in BigEndian() and LittleEndian() functions.
		big_endian = false,
		
		declaring_local_var = false,
		
		-- Stack of statements currently being executed, used for error reporting.
		st_stack = {},
		
		template_error = _template_error,
	}
	
	for k, v in pairs(_builtin_functions)
	do
		context.functions[k] = v
	end
	
	local base_types = {};
	for k, v in pairs(_builtin_types)
	do
		base_types[k] = v
	end
	
	local base_vars = {}
	for k, v in pairs(_builtin_variables)
	do
		base_vars[k] = v
	end
	
	table.insert(context.stack, {
		frame_type = FRAME_TYPE_BASE,
		
		var_types = base_types,
		vars = base_vars,
	})
	
	_exec_statements(context, statements)
	
	local set_comments = function(set_comments, name, type_info, value)
		local do_struct = function(v)
			for k,m in _sorted_pairs(v)
			do
				set_comments(set_comments, k, m[1], m[2])
			end
		end
		
		if type_info.is_array and type_info.base == "struct"
		then
			local elem_type = _make_nonarray_type(type_info)
			
			for i = 1, #value
			do
				do_struct(value[i])
				
				local data_start, data_end = value[i]:data_range()
				if data_start ~= nil
				then
					context.interface.set_comment(data_start, (data_end - data_start), name .. "[" .. (i - 1) .. "]")
				end
			end
		else
			if type_info.base == "struct"
			then
				do_struct(value)
			end
			
			local data_start, data_end = value:data_range()
			if data_start ~= nil
			then
				context.interface.set_comment(data_start, (data_end - data_start), name)
			end
		end
	end
	
	local set_types = function(set_types, name, type_info, value)
		local do_struct = function(v)
			for k,m in _sorted_pairs(v)
			do
				set_types(set_types, k, m[1], m[2])
			end
		end
		
		if type_info.is_array and type_info.base == "struct"
		then
			local elem_type = _make_nonarray_type(type_info)
			
			for i = 1, #value
			do
				do_struct(value[i])
			end
		elseif type_info.base == "struct"
		then
			do_struct(value)
		elseif type_info.rehex_type ~= nil
		then
			-- If this is a char array we assume it is a string and don't set the s8 data type
			-- for the range, else it would be displayed as a list of integers rather than a
			-- contiguous byte sequence.
			
			if not (type_info.is_array and (type_info.type_key == _builtin_types.char.type_key or type_info.type_key == _builtin_types.uint8_t.type_key))
			then
				local data_start, data_end = value:data_range()
				if data_start ~= nil
				then
					context.interface.set_data_type(data_start, (data_end - data_start), type_info.rehex_type)
				end
			end
		end
	end
	
	for k,v in _sorted_pairs(context.global_vars)
	do
		set_comments(set_comments, k, v[1], v[2])
		set_types(set_types, k, v[1], v[2])
	end
end

M.execute = execute

return M