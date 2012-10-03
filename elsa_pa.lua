#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: elsa_pa.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Wed Oct  3 11:47:19 2012 mstenber
-- Last modified: Wed Oct  3 17:21:33 2012 mstenber
-- Edit time:     7 min
--

-- the main logic around with prefix assignment within e.g. BIRD works
-- 
-- elsa_pa is given skv instance, elsa instance, and should roll on
-- it's way. 

require 'mst'
local pa = require 'pa'

module(..., package.seeall)

elsa_pa = mst.create_class{class='elsa_pa', mandatory={'skv', 'elsa'}}

function elsa_pa:init()
   self.pa = pa.pa:new{rid='myrid'}
end

function elsa_pa:uninit()

   -- we don't 'own' skv or 'elsa', so we don't do anything here,
   -- except clean up our own state

   self.pa:done()
end

function elsa_pa:run()
   
end
