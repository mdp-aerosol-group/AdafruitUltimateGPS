module AdafruitUltimateGPS

using LibSerialPort
using Dates
using DataStructures
using Lazy

const dataBuffer = CircularBuffer{UInt8}(5000)

""" 
function config(portname::String)

Set up the serial port configuration for the Adafruit sensor. 

Example usage:

```julia
using AdafruitUltimateGPS.config("/dev/ttyUSB0")
```

To identify the port run the following in the REPL. The port name
varies between different operating systems and may depend on other ports
present in the system.
```julia
julia> using LibSerialPort
julia> list_ports()
/dev/ttyUSB0
	Description:	CP2102N USB to UART Bridge Controller
	Transport type:	SP_TRANSPORT_USB
```

"""
function config(portname::String)
    port = LibSerialPort.sp_get_port_by_name(portname)

    LibSerialPort.sp_open(port, SP_MODE_READ_WRITE)
    config = LibSerialPort.sp_get_config(port)
    LibSerialPort.sp_set_config_baudrate(config, 9600)
    LibSerialPort.sp_set_config_parity(config, SP_PARITY_NONE)
    LibSerialPort.sp_set_config_bits(config, 8)
    LibSerialPort.sp_set_config_stopbits(config, 1)

    return port
end

"""
function stream(port::Ptr{LibSerialPort.Lib.SPPort}, file::String)

Read sensor at 1Hz frequency and stream data to data file. The function is blocking
so it should be called with @async. 

```julia
julia> using AdafruitUltimateGPS
julia> port = AdafruitUltimateGPS.config("/dev/ttyUSB0")
julia> @async AdafruitUltimateGPS.stream(port, "data.txt")
Task (runnable) @0x00007f355935ef80

julia>
"""
function stream(port::Ptr{LibSerialPort.Lib.SPPort}, file::String)
    Godot = @task _ -> false

    run(`touch $(file)`)

    function read(port, file)
        try
            nbytes_read, bytes = LibSerialPort.sp_nonblocking_read(port, 512)
            str = String(bytes[1:nbytes_read])
            filter(x -> x .== "\n", str)
            open(file, "a") do io
                write(io, str)
            end
            append!(dataBuffer, bytes[1:nbytes_read])
        catch
            println("I fail")
        end
    end

    while(true)
        read(port, file)
        sleep(1)
    end

    wait(Godot)
end

"""
function is_valid_NMEA(msg) 

Tests if msg string is valid NMEA message by comparing the stated checksum with the 
calculated checksum. Returns true if valid and false otherwise

```julia
julia> using AdafruitUltimateGPS
julia> msg = "\$GNRMC,151342.000,A,3546.8937,N,07840.5759,W,0.40,22.10,150922,,,D*5B\r"
julia> AdafruitUltimateGPS.is_valid_NMEA_msg(msg)
true
julia>
```
"""
function is_valid_NMEA(msg)
    valid = try
        chk1 = @as x msg split(x, "\n") split(x[1], "*") parse(UInt8, x[2]; base = 16)
        chk2 = @as x msg split(x, "\$") split(x[2], "*") Vector{UInt8}(x[1]) reduce(⊻, x)
        chk1 == chk2
    catch
        false
    end
    return valid
end

function is_valid_RMC(msg)
    valid = try
        (msg[4:6] .== "RMC") && (@as x split(msg, ",") x[3] isequal(x, "A"))
    catch
        false
    end
    return valid
end

"""
function decode_RMC(msg) 

Decodes RMC message and return t, latitude, and longitude as a named tuple.

```julia
julia> using AdafruitUltimateGPS
julia> msg = "\$GNRMC,151342.000,A,3546.8937,N,07840.5759,W,0.40,22.10,150922,,,D*5B\r"
julia> AdafruitUltimateGPS.decode_RMC(msg)
(t = DateTime("2022-09-15T15:13:42"), lat = 35.7815616607666, lon = -78.67626501719157)

julia>
```
"""
function decode_RMC(msg)
    x = split(msg, ",")
    t = DateTime(x[10][1:4] * "20" * x[10][5:6] * x[2], "ddmmyyyyHHMMSS.ss")
    lat = parse(Float32, x[4][1:2]) + parse(Float32, x[4][3:end]) / 60.0
    (x[5] == "N") || (lat = -lat)
    lon = parse(Float32, x[6][1:3]) + parse(Float32, x[6][4:end]) / 60.0
    (x[7] == "E") || (lon = -lon)

    return (t = t, lat = lat, lon = lon)
end

"""
function get_current_RMC()

Filters through the data Buffer and returns current RMC as a tuple of time (UTC), lat and lon.

```julia
julia> using AdafruitUltimateGPS
julia> port = AdafruitUltimateGPS.config("/dev/ttyUSB0")
julia> @async AdafruitUltimateGPS.stream(port, "foo.txt")
julia> AdafruitUltimateGPS.get_current_RMC()
(t = Dates.DateTime("2022-09-15T18:42:21"), lat = 35.78149998982747, lon = -78.67622000376383)
```
"""
function get_current_RMC()
    RMC = @as x begin
        deepcopy(dataBuffer[1:end])
        String(x) 
        split(x, "\n") 
        filter(is_valid_NMEA, x) 
        filter(is_valid_RMC, x) 
        map(decode_RMC, x)
        x[end]
    end
    return RMC
end

end
