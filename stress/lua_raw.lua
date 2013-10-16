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
-- Last modified: Wed Oct 16 16:17:31 2013 mstenber
-- Edit time:     27 min
--

-- Raw lua performance testing (without busted dependency so that we
-- can also run this on device)

require 'mst_test'

local ptest = mst_test.perf_test:new_subclass{duration=5}

local nop = ptest:new{cb=function ()
                         -- nop
                         end,
                      name='nop',
                     }

ptest:new{cb=function ()
             mst.d('x')
end,
          name='mst.d',
          overhead={nop},
         }:run()

ptest:new{cb=function ()
             mst.a(true)
end,
          name='mst.a',
          overhead={nop},
         }:run()

local rnd = ptest:new{cb=function ()
                         mst.randint(1, 100)
                         end,
                      name='randint(1,100)',
                      overhead={nop},
                     }

N_ARRAY_ITEMS=1000
N_REMOVE=N_ARRAY_ITEMS/10

local init_array=function ()
   local a = mst.array:new{}
   for i=1,N_ARRAY_ITEMS
   do
      a:insert(i)
   end
   return a
end

local init_iset=function ()
   local a = mst.iset:new{}
   for i=1,N_ARRAY_ITEMS
   do
      a:insert(i)
   end
   return a
end

-- test how fast remove_index (=table.remove) is

local ia = ptest:new{cb=init_array,
                     name='init_array',
                     overhead={nop}}

local ra = ptest:new{cb=function ()
                        local a = init_array()
                        for i=1,N_REMOVE
                        do
                           a:remove_index(mst.randint(1, #a))
                        end
                        end,
                     name='array remove_index+randint xN',
                     overhead={nop, ia}}
ra:run()

-- test how fast remove (in iset) is

local is = ptest:new{cb=init_iset,
                     name='init_iset',
                     overhead={nop}}

local rs = ptest:new{cb=function ()
                        local a = init_iset()
                        for i=1,N_REMOVE
                        do
                           a:remove(a:randitem())
                        end
                        end,
                     name='iset remove_index+randitem xN',
                     overhead={nop, is}}
rs:run()

-- test how native fast table set/remove is

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
