#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dns_tree.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Tue May  7 12:55:42 2013 mstenber
-- Last modified: Tue May  7 13:45:01 2013 mstenber
-- Edit time:     29 min
--

-- This module implements (nested) dns zone hierarchy using rather
-- simple API which wraps set of objects.

-- There are tree nodes, and leaf nodes; both can have values (=a list
-- of RRs related to that particular FQDN), and the tree nodes can
-- have also child nodes.

require 'mst'

module(..., package.seeall)

node = mst.create_class{name='node', 
                        mandatory={'label'}}

function node:init()
   self.children = {}
end

function node:repr_data()
   return mst.repr{children=self.children and mst.table_count(self.children) or 0,
                   label=self.label}
end

function node:add_child(n)
   self.children[string.lower(n.label)] = n
   return n
end

function node:get_child(label)
   return self.children[string.lower(label)]
end

function node:match_rec(ll, i, ...)
   if i == 0
   then
      return self:get_value(...)
   end
   self:a(i <= #ll)
   local label = ll[i]
   local child = self:get_child(label)
   if not child
   then
      return self:get_default(...)
   end
   return child:match_rec(ll, i-1, ...)
end

function node:match_ll(ll, ...)
   return self:match_rec(ll, #ll, ...)
end

function node:find_or_create_subtree_rec(ll, i, end_node_class, d, 
                                         intermediate_node_class)
   local label = ll[i]
   local n = self:get_child(label)
   if i == 1
   then
      -- this is the last node 
      if n
      then
         return n
      end
      -- add child with that label
      d = d or {}
      d.label = label
      d.parent = self
      self:a(end_node_class)
      return self:add_child(end_node_class:new(d))
   end
   -- intermediate node
   if not n
   then
      self:a(intermediate_node_class)
      n = intermediate_node_class:new{label=label, parent=self}
      self:add_child(n)
   end
   return n:find_or_create_subtree_rec(ll, i-1, end_node_class, d, 
                                       intermediate_node_class)
end


function node:find_or_create_subtree(ll, end_node_class, d, 
                                     intermediate_node_class)
   self:a(ll, 'no ll supplied')
   self:a(end_node_class, 'no end node class supplied')
   intermediate_node_class = intermediate_node_class or mst.get_class(self)
   return self:find_or_create_subtree_rec(ll, #ll, end_node_class, d, 
                                          intermediate_node_class)
end

function node:add_value(ll, value)
   local n = self:find_or_create_subtree(ll, leaf_node, {value=value})
   self:a(n,  'find_or_create_subtree failed?!?')
   n.value = value
   return n
end


function node:get_fqdn()
   return table.concat(self:get_ll(), '.')
end

function node:get_ll()
   local t = {}
   local n = self
   while #n.label > 0
   do
      table.insert(t, n.label)
      n = n.parent
   end
   return t
end

function node:get_default()
   return nil, 'default value not provided'
end

function node:get_value()
   return nil, 'value not provided'
end

leaf_node = node:new_subclass{name='leaf_node',
                              mandatory={'label', 'parent', 'value'}}

function leaf_node:get_default()
   return nil, 'leaf nodes cannot have children'
end

function leaf_node:get_value()
   return self.value
end

