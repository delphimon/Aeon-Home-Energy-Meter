-- Copyright 2021 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.


-- To do
-- - Delete dump(o)
-- - Add custom capability for amps and cost (i.e. price * kwh)
-- - Add reset option
-- - Add CRC16 encapsulation

local capabilities = require "st.capabilities"
--- @type st.zwave.CommandClass.Configuration
local Configuration = (require "st.zwave.CommandClass.Configuration")({ version=1 })
--- @type st.zwave.CommandClass.Meter
local Meter = (require "st.zwave.CommandClass.Meter")({ version=3 })
--- @type st.zwave.CommandClass
local cc = require "st.zwave.CommandClass"
local log = require "log"
local preferencesMap = require "preferences"



local AEOTEC_GEN1_FINGERPRINTS = {
  {mfr = 0x0086, prod = 0x0002, model = 0x0009},  -- Aeotec Home Energy Meter (Gen1) US
}

local POWER_UNIT_WATT = "W"
local ENERGY_UNIT_KWH = "kWh"
local VOLTAGE_UNIT_V = "V"
local AMPERE_UNIT_A = "A"

local intIndentCounter = 0
local function dump(o) 
    if type(o) == 'table' then
intIndentCounter = intIndentCounter + 1
        local s = string.sub("                                    ",1,intIndentCounter) .. '{ '
        for k,v in pairs(o) do
log.warn("Found pair called", k, v)
                if type(k) ~= 'number' then k = '"'..k..'"' end
                s = s .. '['..k..'] = ' .. dump(v) .. ','
        end
intIndentCounter = intIndentCounter - 1
        return s .. '}\n\r '
    else
        return tostring(o)
    end
end

--- Handle preference changes
---
--- @param driver st.zwave.Driver
--- @param device st.zwave.Device
--- @param event table
--- @param args
local function info_changed(driver, device, event, args)
  local groupArray = { g1 = { value = 0, changed = false}, g2 = { value = 0, changed = false}, g3 = { value = 0, changed = false}}
  local preferences = preferencesMap.get_device_parameters(device)

  if preferences then
    for id, value in pairs(device.preferences) do
      if(groupArray[string.sub(id,1,2)]) then -- Record all the binary values in the groups 1-3 to set params 101-103
		groupArray[string.sub(id,1,2)].value = groupArray[string.sub(id,1,2)].value + preferencesMap.to_numeric_value(device.preferences[id])
        if args.old_st_store.preferences[id] ~= value then
          groupArray[string.sub(id,1,2)].changed = true
		end
	  end

      if args.old_st_store.preferences[id] ~= value and preferences[id] then
        local new_parameter_value = preferencesMap.to_numeric_value(device.preferences[id])
		log.info("About to set zwave parameter:", preferences[id].parameter_number, preferences[id].size, new_parameter_value)
        device:send(Configuration:Set({parameter_number = preferences[id].parameter_number, size = preferences[id].size, configuration_value = new_parameter_value}))
      end
    end
    for group, array in pairs(groupArray) do
      if array.changed then
	    log.info("About to set parameter for group setting", "value" .. group, " to ", array.value)
        device:send(Configuration:Set({parameter_number = preferences["value" .. group].parameter_number, size = preferences["value" .. group].size, configuration_value = array.value}))
      end
	end
	
	device:send(Configuration:Get({}))
log.info("Just forced a device parameter referesh and they now look like:")
	dump(device.preferences)
  end
end


local function can_handle_aeotec_gen1_meter(opts, driver, device, ...)
  for _, fingerprint in ipairs(AEOTEC_GEN1_FINGERPRINTS) do
    if device:id_match(fingerprint.mfr, fingerprint.prod, fingerprint.model) then
     return true
    end
  end
  return false
end

local do_configure = function (self, device)
--  device:send(Configuration:Set({parameter_number = 101, size = 4, configuration_value = 592128})) -- all clamp 1
--  device:send(Configuration:Set({parameter_number = 102, size = 4, configuration_value = 1184256})) -- all clamp 2
--  device:send(Configuration:Set({parameter_number = 103, size = 4, configuration_value = 2368512})) -- all clamp 3
--  device:send(Configuration:Set({parameter_number = 101, size = 4, configuration_value = 3}))   -- report total power in Watts and total energy in kWh...
--  device:send(Configuration:Set({parameter_number = 102, size = 4, configuration_value = 0}))  - -- disable group 2...
--  device:send(Configuration:Set({parameter_number = 103, size = 4, configuration_value = 0}))   -- disable group 3...
  device:send(Configuration:Set({parameter_number = 111, size = 4, configuration_value = 300})) -- ...every 5 min
  device:send(Configuration:Set({parameter_number = 112, size = 4, configuration_value = 300})) -- ...every 5 min
  device:send(Configuration:Set({parameter_number = 113, size = 4, configuration_value = 300})) -- ...every 5 min
--  device:send(Configuration:Set({parameter_number = 90, size = 1, configuration_value = 0}))    -- enabling automatic reports, disabled selective reporting...
--  device:send(Configuration:Set({parameter_number = 13, size = 1, configuration_value = 1}))   -- disable CRC16 encapsulation
end



function meter_report_handler(self, device, cmd)
  local event_arguments = nil
  if cmd.args.scale == Meter.scale.electric_meter.KILOWATT_HOURS then
    event_arguments = {
      value = cmd.args.meter_value,
      unit = ENERGY_UNIT_KWH
    }
    device:emit_event_for_endpoint(
      cmd.src_channel,
      capabilities.energyMeter.energy(event_arguments)
    )
  elseif cmd.args.scale == Meter.scale.electric_meter.WATTS then
     local event_arguments = {
      value = cmd.args.meter_value,
      unit = POWER_UNIT_WATT
    }
    device:emit_event_for_endpoint(
      cmd.src_channel,
      capabilities.powerMeter.power(event_arguments)
    )
  elseif cmd.args.scale == Meter.scale.electric_meter.VOLTS then
     local event_arguments = {
      value = cmd.args.meter_value,
      unit = VOLTAGE_UNIT_V
    }
    device:emit_event_for_endpoint(
      cmd.src_channel,
      capabilities.voltageMeasurement.voltage(event_arguments)
    )
  end
end

local function component_to_endpoint(device, component_id)
  local ep_str = component_id:match("Clamp(%d)")
  local ep_num = ep_str and math.floor(ep_str)
  log.trace("component_to_endpoint ", ep_str, ep_num)
  return {ep_num and tonumber(ep_num)} or {}
end
  
local function endpoint_to_component(device, ep)
  local meter_comp = string.format("Clamp%d", ep)
  if device.profile.components[meter_comp] ~= nil then
    return meter_comp
  else
    return "main"
  end
end

local device_init = function(self, device)
  device:set_component_to_endpoint_fn(component_to_endpoint)
  device:set_endpoint_to_component_fn(endpoint_to_component)
end


local aeotec_gen1_meter = {
  supported_capabilities = {
	capabilities.refresh
  },
  zwave_handlers = {
    [cc.METER] = {
      [Meter.REPORT] = meter_report_handler
    }
  },
  lifecycle_handlers = {
    doConfigure = do_configure,
	infoChanged = info_changed,
	init = device_init
  },
  NAME = "aeotec gen1 meter",
  can_handle = can_handle_aeotec_gen1_meter
}

return aeotec_gen1_meter
