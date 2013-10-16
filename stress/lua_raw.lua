#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: lua_raw.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed Oct 16 13:35:59 2013 mstenber
-- Last modified: Wed Oct 16 14:55:17 2013 mstenber
-- Edit time:     12 min
--

-- Raw lua performance testing (without busted dependency so that we
-- can also run this on device)

require 'mst_test'

local ptest = mst_test.perf_test:new_subclass{duration=1}

local nop = ptest:new{cb=function ()
                         -- nop
                         end,
                      name='nop',
                     }

local rnd = ptest:new{cb=function ()
                         mst.randint(1, 100)
                         end,
                      name='randint(1,100)',
                      overhead={nop},
                     }

N_ARRAY_ITEMS=10000

local init_array=function ()
   local a = mst.array:new{}
   for i=1,N_ARRAY_ITEMS
   do
      a:insert(i)
   end
   return a
end

local ia = ptest:new{cb=init_array,
                     name='init_array'}

local ra = ptest:new{cb=function ()
                        local a = init_array()
                        a:remove_index(mst.randint(1, N_ARRAY_ITEMS))
                        end,
                     name='remove_index',
                     overhead={ia}}
ra:run()

local t = {}
ptest:new{cb=function ()
             local i = mst.randint(1, 100)
             local m = mst.randint(0, 1)
             if m == 0
             then
                t[i] = nil
             else
                t[i] = true
             end
end,
          name='table set/remove',
          overhead={rnd, rnd},
         }:run()
