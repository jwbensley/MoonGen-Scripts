package.path = package.path .. ";/opt/dpdk/MoonGen/rfc2544/?.lua"

--[[
local standalone = false
if master == nil then
        standalone = true
        master = "dummy"
end
--]]

local arp           = require "proto.arp"
local barrier       = require "barrier"
local device        = require "device"
local dpdk          = require "dpdk"
local ffi           = require "ffi"
local filter        = require "filter"
local hist          = require "histogram"
local memory        = require "memory"
local mg            = require "moongen"
--local tikz          = require "utils.tikz"
local timer         = require "timer"
local ts            = require "timestamping"
local utils         = require "utils.utils"

-- Global defaults:
local DEF_DURATION = 10
local DEF_DST_PORT = 319
local DEF_FRAME_SIZES = "84,128,256,512,1024,1280,1518"
local DEF_RATE = 10000
local DEF_RX_GW = "198.19.1.1"
local DEF_RX_IP = "198.19.1.2"
local DEF_RX_QUEUES = 2
local DEF_SRC_PORT = 319 -- Some NIC drivers only support hardware timestamp offloading if the UDP source port is PTP
local DEF_TX_GW = "198.18.1.1"
local DEF_TX_IP = "198.18.1.2"
local DEF_TX_QUEUES = 2 -- FIXME: Do we want different queue number for Tx and Rx port?
-- Original code:
--        txDev = device.config({port = txPort, rxQueues = 2, txQueues = 5})
--        rxDev = device.config({port = rxPort, rxQueues = 3, txQueues = 1})


-- Construct a new table called "benchmark" then set it's __index metamethod to
-- be itself and the table to be it's own metatable:
local benchmark = {}
benchmark.__index = benchmark

function benchmark.create()
    local self = setmetatable({}, benchmark)
    self.initialized = false
    return self
end
setmetatable(benchmark, {__call = benchmark.create})


function benchmark:init(arg)
    self.rxQueues = arg.rxQueues
    self.txQueues = arg.txQueues
    
    self.duration = arg.duration
    self.rate = arg.rate

    self.dport = arg.dport
    self.sport = arg.sport

    self.skipConf = arg.skipConf

    self.initialized = true -- FIXME: Is this needed?
end

function benchmark:getCSVHeader()
    return "latency,packet,frame size,rate,duration"
end

function benchmark:resultToCSV(result)
    local str = ""
    result:calc()
    for k ,v in ipairs(result.sortedHisto) do
            str = str .. v.k .. "," .. v.v .. "," .. result.frameSize .. "," .. result.rate .. "," .. self.duration
        if result.sortedHisto[k+1] then
            str = str .. "\n"
        end
    end
    return str
end

function benchmark:bench(frameSize)
    if not self.initialized then
        return print("benchmark table not initialized, skipping test " .. frameSize .. " " .. self.rate);
    elseif frameSize == nil then
        return error("benchmark table got invalid frameSize, skipping test" .. frameSize .. " " .. self.rate);
    end

    print("Testing with frame size of "..frameSize)

    local maxLinkRate = self.txQueues[1].dev:getLinkStatus().speed
    print("Max link rate is " .. maxLinkRate)

    local bar = barrier.new(0,0) -- FIXME: The 1st arg is 0 and 2nd is 1, barrier.new(n) uses arg[1]
    
    -- workaround for rate bug
    local numQueues = self.rate > (64 * 64) / (84 * 84) * maxLinkRate and self.rate < maxLinkRate and 3 or 1 -- Setting 3 queues if rate > 5804.98Mbps -- FIXME: Remove
    print("Number of Tx queues set to " .. numQueues) -- FIXME: Remove
    bar:reinit(numQueues + 1)
    if self.rate < maxLinkRate then
        -- not maxLinkRate
        -- eventual multiple slaves
        -- set rate is payload rate not wire rate
        for i=1, numQueues do
            printf("Set queue %d to rate %d", i, self.rate * frameSize / (frameSize + 20) / numQueues)
            self.txQueues[i]:setRate(self.rate * frameSize / (frameSize + 20) / numQueues)
        end
    else
        -- maxLinkRate
        printf("Set single queue 1 to rate %d", self.rate) -- FIXME: Remove
        self.txQueues[1]:setRate(self.rate)
    end
    
    -- traffic generator
    local loadSlaves = {}
    for i=1, numQueues do
        --table.insert(loadSlaves, dpdk.launchLua("latencyLoadSlave", self.txQueues[i], port, frameSize, self.duration, mod, bar))
        table.insert(loadSlaves, mg.startTask("latencyLoadSlave", self.txQueues[i], self.dport, self.sport, frameSize, self.duration, mod, bar))
    end
    
    local hist = latencyTimerSlave(self.txQueues[numQueues+1], self.rxQueues[1], self.dport, self.sport, frameSize, self.duration, bar)
    hist:print()
    
    local spkts = 0
    for _, sl in pairs(loadSlaves) do
        spkts = spkts + sl:wait()
    end

    if not self.skipConf then -- FIXME: Not needed?
        self:undoConfig()
        print("Called UndoConfig()")
    else
        print("Skipped Undo")
    end

    hist.frameSize = frameSize
    hist.rate = spkts / 10^6 / self.duration
    return hist
end

function latencyLoadSlave(queue, dport, sport, frameSize, duration, modifier, bar)
    local ethDst = arp.blockingLookup("198.18.1.1", 10)
    --TODO: error on timeout

    -- gen payload template suggested by RFC2544
    local udpPayloadLen = frameSize - 46
    local udpPayload = ffi.new("uint8_t[?]", udpPayloadLen)
    for i = 0, udpPayloadLen - 1 do
        udpPayload[i] = bit.band(i, 0xf)
    end

    local mem = memory.createMemPool(function(buf)
        local pkt = buf:getUdpPacket()
        pkt:fill{
            pktLength = frameSize - 4, -- self sets all length headers fields in all used protocols, -4 for FCS
            ethSrc = queue, -- get the src mac from the device
            ethDst = ethDst,
            ip4Dst = "198.19.1.2",
            ip4Src = "198.18.1.2",
            --udpSrc = SRC_PORT,
            udpSrc = sport,
        }
        -- fill udp payload with prepared udp payload
        ffi.copy(pkt.payload, udpPayload, udpPayloadLen)
    end)

    local bufs = mem:bufArray()
    --local modifierFoo = utils.getPktModifierFunction(modifier, baseIp, wrapIp, baseEth, wrapEth)

    -- TODO: RFC2544 routing updates if router
    -- send learning frames: 
    --      ARP for IP

    local sendBufs = function(bufs, dport) 
        -- allocate buffers from the mem pool and store them in self array
        bufs:alloc(frameSize - 4)

        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            -- set packet udp port
            pkt.udp:setDstPort(dport)
            -- apply modifier like ip or mac randomisation to packet
            --modifierFoo(pkt)
        end
        -- send packets
        bufs:offloadUdpChecksums()
        return queue:send(bufs)
    end
    -- warmup phase to wake up card
    local t = timer:new(0.1)
    while t:running() do
        sendBufs(bufs, dport + 1)
    end


    -- sync with timerSlave
    bar:wait()

    -- benchmark phase
    local totalSent = 0
    t:reset(duration + 2)
    while t:running() do
        totalSent = totalSent + sendBufs(bufs, dport)
    end
    return totalSent
end

function latencyTimerSlave(txQueue, rxQueue, dport, sport, frameSize, duration, bar)
    --Timestamped packets must be > 80 bytes (+4crc)
    frameSize = frameSize > 84 and frameSize or 84 -- FIXME: Need to check CLI arg is >84
    
    local ethDst = arp.blockingLookup("198.18.1.1", 10)
    --TODO: error on timeout
        
    --rxQueue.dev:filterTimestamps(rxQueue)
    rxQueue.filterUdpTimestamps(rxQueue)

    local timestamper = ts:newUdpTimestamper(txQueue, rxQueue)
    local hist = hist:new()
    local rateLimit = timer:new(0.001)

    -- sync with load slave and wait additional few milliseconds to ensure 
    -- the traffic generator has started
    bar:wait()
    mg.sleepMillis(1000)
    
    local t = timer:new(duration)
    while t:running() do
        hist:update(timestamper:measureLatency(frameSize - 4, function(buf)
            local pkt = buf:getUdpPacket()
            pkt:fill({
                -- TODO: timestamp on different IPs
                ethSrc = txQueue,
                ethDst = ethDst,
                ip4Src = "198.18.1.2",
                ip4Dst = "198.19.1.2",
                udpSrc = sport,
                udpDst = dport,
                pktLength = frameSize - 4
            })
        end))
        rateLimit:wait()
        rateLimit:reset()
    end
    return hist
end


function configure(parser)
    parser:description("Generates bidirectional CBR traffic with hardware rate control and measure latencies.") -- FIXME:Is this an accurate description?
    parser:argument("txport", "Device ID to transmit from."):convert(tonumber)
    parser:argument("rxport", "Device ID to receive on."):convert(tonumber)
    parser:option("-d --duration", "Test duration in seconds. Default: " .. DEF_DURATION):default(DEF_DURATION):convert(tonumber)
    parser:option("-r --rate", "Transmit rate in Mbit/s. Default: " .. DEF_RATE):default(DEF_RATE):convert(tonumber)
    parser:option("-s --sizes", "Comma seperated list of frame sizes. Default " .. DEF_FRAME_SIZES):default(DEF_FRAME_SIZES):convert(tostring)
    parser:option("-rq --rxqueues", "Number of Rx queues. Default: " .. DEF_RX_QUEUES):default(DEF_RX_QUEUES):convert(tonumber)
    parser:option("-tq --txqueues", "Number of Tx queues. Default: " .. DEF_TX_QUEUES):default(DEF_TX_QUEUES):convert(tonumber)
    parser:option("-dp --dport", "UDP destination port number. Default " .. DEF_DST_PORT):default(DEF_DST_PORT):convert(tonumber)
    parser:option("-sp --sport", "UDP source port numer. Default " .. DEF_SRC_PORT):default(DEF_DST_PORT):convert(tonumber)
end


function master(args)

	-- parse frame sizes
	local frameSizes={}
	local i=1

	for str in string.gmatch(args.sizes, "%d+") do
	    frameSizes[i] =tonumber(str)
	    i = i + 1
	end

	io.write("Frame sizes set to: ")
	for j=1,#frameSizes do
        io.write(frameSizes[j].." ")
    end
    io.write("\n")

    local txPort, rxPort = args.txport, args.rxport

    local rxDev, txDev

    if txPort == rxPort then
        -- sending and receiving from the same port
        --[[
            device.config():
            https://scholzd.github.io/MoonGen/device_8lua.html
            https://github.com/libmoon/libmoon/blob/master/lua/device.lua
            --- Configure a device
            --- @param args A table containing the following named arguments
            ---   port Port to configure
            ---   mempools optional (default = create new mempools) RX mempools to associate with the queues
            ---   rxQueues optional (default = 1) Number of RX queues to configure 
            ---   txQueues optional (default = 1) Number of TX queues to configure 
            ---   rxDescs optional (default = 512)
            ---   txDescs optional (default = 1024)
            ---   numBufs optional (default max(2047, rxDescs * 2 -1))
            ---   bufSize optional (default = 2048)
            ---   speed optional (default = 0/max) Speed in Mbit to negotiate (currently disabled due to DPDK changes)
            ---   dropEnable optional (default = true) Drop rx packets directly if no rx descriptors are available
            ---   rssQueues optional (default = 0) Number of queues to use for RSS
            ---   rssBaseQueue optional (default = 0) The first queue to use for RSS, packets will go to queues rssBaseQueue up to rssBaseQueue + rssQueues - 1
            ---   rssFunctions optional (default = all supported functions) Table with hash functions specified in dpdk.ETH_RSS_*
            ---   disableOffloads optional (default = false) Disable all offloading features, this significantly speeds up some drivers (e.g., ixgbe).
            ---                   set by default for drivers that do not support offloading (e.g., virtio)
            ---   stripVlan (default = true) Strip the VLAN tag on the NIC.
        --]]
         -- FIXME: Disable dropEnable? Enable rssQueus?
        txDev = device.config({port = txPort, rxQueues = args.rxqueues, txQueues = args.txqueues})
        rxDev = txDev
    else
        -- two different ports, different configuration
        txDev = device.config({port = txPort, rxQueues = args.rxqueues, txQueues = args.txqueues})
        rxDev = device.config({port = rxPort, rxQueues = args.rxqueues, txQueues = args.txqueues})
    end

    print("Waiting for device links to initialise...")
    device.waitForLinks()
    print("Done.")
    
    print("ARPing for default gateway(s)...")
    if txPort == rxPort then
        mg.startTask(arp.arpTask, {
            { 
                txQueue = txDev:getTxQueue(0),
                rxQueue = txDev:getRxQueue(0),
                --ips = {"198.18.1.2", "198.19.1.2", "198.18.1.1"} -- FIXME: Make IPs variables
                ips = {"198.18.1.1", "198.19.1.1"}
            }
        })
    else
        mg.startTask(arp.arpTask, {
            {
                txQueue = txDev:getTxQueue(0),
                rxQueue = txDev:getRxQueue(0),
                ips = {"198.18.1.1"} -- FIXME: Make IPs variables
            },
            {
                txQueue = rxDev:getTxQueue(0),
                rxQueue = rxDev:getRxQueue(0),
                --ips = {"198.19.1.2", "198.18.1.1", "198.18.1.1"} -- FIXME: Make IPs variables
                ips = {"198.19.1.1"}
            }
        })
    end
    print("Done.")
    
    local bench = benchmark()
    local rxQueueSet = {}
    local txQueueSet = {}

    for i=0,args.rxqueues-1 do
        table.insert(rxQueueSet, rxDev:getRxQueue(i))
    end

    for i=0,args.txqueues-1 do
        table.insert(txQueueSet, txDev:getTxQueue(i))
    end


    bench:init({
        txQueues = txQueueSet, -- FIXME: Make queue count variable
        rxQueues = rxQueueSet,  -- FIXME: Make queue count variable
        duration = args.duration,
        rate = args.rate,
        dport = args.dport,
        sport = args.sport,
        skipConf = true,
    })

    
    --print(bench:getCSVHeader())
    local results = {}        
    for _, frameSize in ipairs(frameSizes) do
        local result = bench:bench(frameSize)
        -- save and report results
        table.insert(results, result)
        print(bench:getCSVHeader())
        print(bench:resultToCSV(result))
    end

end
