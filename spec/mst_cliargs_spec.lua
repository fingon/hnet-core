#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mst_cliargs_spec.lua $
--
-- Author: Markus Stenberg <mstenber@cisco.com>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Fri Jul 19 10:23:38 2013 mstenber
-- Last modified: Mon Oct 21 10:50:04 2013 mstenber
-- Edit time:     2 min
--

-- Moved here from mst_spec.lua (so that we can really get stand-alone
-- tests of the stuff done, strict works better, etc)

require "busted"
require "mst_cliargs"
require "mst_test"

module("mst_cliargs_spec", package.seeall)

local ERR = -42

local cliargs_tests = {
   {
      -- no input =>
      {
         arg={[0]='dummy'},
      },
      -- should result in nop
      {0, {}},
   },
   {
      -- help =>
      {
         arg={[0]='dummy', '-h'},
      },
      -- should result in nop (start line + -h = help)
      {ERR + 2},
   },
   {
      -- no input =>
      {
         arg={[0]='dummy', '--help'},
      },
      -- should result in nop
      {ERR + 2},
   },
   {
      -- no input =>
      {
         arg={[0]='dummy', '--help'},
         options={{value='foo', desc='default'}},
      },
      -- should result in nop
      {ERR + 3},
   },
   {
      -- erroneous input =>
      {
         arg={[0]='dummy', '--asdf'},
      },
      -- should result in error message + help + exit
      {ERR + 3},
   },

   {
      -- valid input (flag)
      {
         arg={[0]='dummy', '--asdf'},
         options={{name='asdf', flag=1}},
      },
      {0, {asdf=true}},
   },


   {
      -- valid input (value)
      {
         arg={[0]='dummy', '--asdf=x'},
         options={{name='asdf'}},
      },
      {0, {asdf='x'}},
   },

   {
      -- valid input (multivalue)
      {
         arg={[0]='dummy', '--asdf=x'},
         options={{name='asdf', max=123}},
      },
      {0, {asdf={'x'}}},
   },

   {
      -- valid input (default arg, 1 allowed)
      {
         arg={[0]='dummy', 'x'},
         options={{value='asdf'}},
      },
      {0, {asdf='x'}},
   },
   {
      -- invalid input (default arg, 1 allowed)
      {
         arg={[0]='dummy', 'x', 'y'},
         options={{value='asdf'}},
      },
      -- should result in error message + help + exit
      {ERR+3+1},
   },

   {
      -- invalid input (multivalue, too few)
      {
         arg={[0]='dummy', '--asdf=x'},
         options={{name='asdf', min=2}},
      },
      {ERR+3+1},
   },


   {
      -- invalid input (multivalue, too many)
      {
         arg={[0]='dummy', '--asdf=x', '--asdf=y'},
         options={{name='asdf', max=1}},
      },
      {ERR+3+1},
   },


   {
      -- default (no args)
      {
         arg={[0]='dummy'},
         options={{name='asdf', default=123}},
      },
      {0, {asdf=123}},
   },


   {
      -- default (with args)
      {
         arg={[0]='dummy', '--asdf=x'},
         options={{name='asdf', default=123}},
      },
      {0, {asdf='x'}},
   },

   {
      -- default (with args, space)
      {
         arg={[0]='dummy', '--asdf', 'x'},
         options={{name='asdf', default=123}},
      },
      {0, {asdf='x'}},
   },

   {
      -- error - trailing opt
      {
         arg={[0]='dummy', '--asdf'},
         options={{name='asdf', default=123}},
      },
      {ERR+3+1},
   },

   {
      -- converted value
      {
         arg={[0]='dummy', '--asdf', '42'},
         options={{name='asdf', default=123, convert=tonumber}},
      },
      {0, {asdf=42}},
   },

   {
      -- conversion error
      {
         arg={[0]='dummy', '--asdf', 'x'},
         options={{name='asdf', default=123, convert=tonumber}},
      },
      {ERR+3+1},
   },

   {
      -- ordering check (should check longest to shortest -> these
      -- options should all work correctly)
      {
         arg={'-a', '--ab', '--abc', 'x'},
         options={{name='a', flag=1},
                  {name='ab', flag=1},
                  {name='abc', flag=1},
                  {value='v'},
         },
      },
      {0, {a=true, ab=true, abc=true, v='x'}},
   },

   -- XXX - add a lot more tests!
   -- desc?
}

describe("mst_cliargs", function ()
            it("works #cli", function ()
                  
                  mst_test.test_list(cliargs_tests, function (o)
                                        local err = 0
                                        function o.error()
                                           -- nop
                                           err = ERR
                                        end
                                        local l = {}
                                        function o.print(...)
                                           mst.d('<print>', ...)
                                           table.insert(l, {...})
                                        end
                                        local r = mst_cliargs.parse(o)
                                        return {#l + err, r}
                                        end)
                   end)
end)
