--[[
 Example MoonGen script to send every possible Ethertype value 0x0000-0xFFFF
 between the SRC and DST MAC addresses specified below.

 The scripts assumes the Tx and Rx devices are the same (i.e. two NICs on the
 same machine looping through a DUT) and not two seperate devices.

 Some NICs won't enter promisc mode, some DUTs won't forward an unknown unicast
 storm, so it generally helps to put your Tx and Rx NIC hardware addresses below,
 but for convenience when testing multicast or broadcast switching, edit the
 variables below.

 The rx thread starts first and runs for 5 seconds before quitting to allow for
 any queuing or latency in the network. 65536 * 64 bytes == ~4M bits to transmit.
 This means thhat the Tx thread should have sent all possible frames in 0.04
 seconds on a 100Mbps NIC, so 5 seconds is plenty of time.

 Please send any corrections to jwbensley@gmail.com or post here:
 https://gist.github.com/jwbensley/20f448908bfc7c77d4097dd3e8f64886
]]--

local PKT_SIZE = 60
local SRC_MAC = "94:18:82:AB:AE:F3"
local DST_MAC = "94:18:82:AB:AE:F4"

-- NOTHING TO EDIT BELOW THIS LINE --

local mg     = require "moongen"
local memory = require "memory"
local device = require "device"
local stats  = require "stats"
local log    = require "log"


function configure(parser)
    parser:argument("txDev", "The device to transmit from"):convert(tonumber)
    parser:argument("rxDev", "The device to transmit from"):convert(tonumber)
    parser:option("-r --rate", "Transmit rate in Mbit/s (default 1000M)."):default(1000):convert(tonumber)
end

function master(args)
    local txDev = device.config{port = args.txDev, dropEnable = false, txQueues = 1, rxQueues = 1}
    --txDev:getTxQueue(0):setRate(args.rate)
    local rxDev = device.config{port = args.rxDev, dropEnable = false, txQueues = 1, rxQueues = 1}
    --rxDev:getRxQueue(0):setRate(args.rate)
    device.waitForLinks()
    mg.setRuntime(5)
    mg.startTask("rxSlave", rxDev:getRxQueue(0))
    mg.startTask("txSlave", txDev, txDev:getTxQueue(0), PKT_SIZE, SRC_MAC, DST_MAC)
    mg.waitForTasks()
end


function txSlave(dev, queue, sz_pkt, srcMac, dstMac)

    local state = "canrun"
    local txStats = stats:newDevTxCounter(queue, "plain")
    local memPools = {}
    local etype = 0
    local num_memPool = 33
    -- Max number of frames in a buffer array is 2047. 2047 * 32 == 65504 frames.
    -- A 33rd buffer array is required to store a final (65536-65503)== 32 frames
    -- to be able to send one frame with each possible EtherType value from 0x000-0xFFFF.

    -- Main loop:
    while state == "canrun" and mg.running() do

        -- Create an array of memPools and buffer arrays:
        for i = 0,num_memPool do
            memPools[i] = {
                mempool  = {},
                bufArray = nil
            }

            -- Init each memPool as an Ethernet frame buffer
            memPools[i].mempool = memory:createMemPool(
                function(buf)
                    buf:getEthernetPacket()
                end
            )

            -- Init each buffer array to the max size of 2047 using the defined memPool
            -- initialised as an Ethernet frame buffer, unless its the final bufArray,
            -- then init to just 32 frames:
            if i == 33 then
                memPools[i].bufArray = memPools[i].mempool:bufArray(32)
            else
                memPools[i].bufArray = memPools[i].mempool:bufArray(2047)
            end
        end


        -- Loop over each buffer array and within each buffer array set the EtherType
        -- for each frame:
        for memPoolID, memPool in ipairs(memPools) do

            -- Allocate each frame within the buffer:
            memPool.bufArray:alloc(sz_pkt)

            -- Modify each frame in the buffer array:
            for frameID, buf in ipairs(memPool.bufArray) do
                local pkt = buf:getEthernetPacket()
                pkt.eth:setType(etype)
                pkt.eth:setSrcString(srcMac)
                pkt.eth:setDstString(dstMac)
                etype = etype + 1
            end

            queue:send(memPool.bufArray)
            txStats:update()

        end

        state = "stop"
    end

    txStats:finalize()
end

function rxSlave(queue)

    local bufs = memory.bufArray()
    local etypes = {}
    local pktCtr = stats:newPktRxCounter("RxPkts", "plain")
    local devCtr = stats:newDevRxCounter("DevPkts", queue.dev, "plain")
    -- pktCtr is counting the packets received by application layer and
    -- passed to the counter.
    -- devCtr is counting packets received on the rxDev device, any
    -- difference in the number of packets received at the device layer and
    -- application layer might indicate a drop within a queue queue.

    while mg.running() do
        local rx = queue:recv(bufs)
        for i = 1, rx do
            local buf = bufs[i]
            local pkt = buf:getEthernetPacket()
            local etype = pkt.eth:getType()
            etypes[etype] = 1
            pktCtr:countPacket(buf)
        end
        pktCtr:update()
        devCtr:update()
        bufs:freeAll()
    end

    pktCtr:finalize()
    devCtr:finalize()

    local nrMia = 0
    for i = 0,65535 do
        if etypes[i] ~= 1 then
            log:warn("Missing etype: 0x%x", i)
            nrMia = nrMia + 1
        end
    end

    log:info("Missing frames: %d", nrMia)

end