
using JSON
using JLD
using StatsBase
using BenchmarkTools
using Glob
using HTTP
# using Libz
# using Base.LibGit2

# push!(LOAD_PATH, @__DIR__)
# using Check

const cachefolder = joinpath(@__DIR__, "dlcache")
const repobase = "https://raw.githubusercontent.com/JuliaCI/BaseBenchmarkReports/master"

function summarize(benchmarks)
    if isdefined(benchmarks, :data)
        return map(benchmarks.data) do entry
            string(entry.first) => summarize(entry.second)
        end
    elseif isdefined(benchmarks, :times)
        return summarystats(benchmarks.times)
    else
        return nothing
    end
end

datedirname(date) = string("daily_", Dates.year(date), "_", Dates.month(date), "_", Dates.day(date))

function get_daily_data(date)
    dailydir = joinpath(cachefolder, date)
    isdir(dailydir) || mkdir(dailydir)
    filegz = joinpath(dailydir, "data.tar.gz")
    if !isfile(filegz)
        uri = string("$repobase/$date/data.tar.gz")
        datagz = HTTP.get(uri)
        status = HTTP.status(datagz)
        if status != 200
            warn("$uri => $status")
            return nothing # assume there is no data for this day
        end
        write(filegz, HTTP.bytes(datagz))
    end
    run(`tar -xzf $filegz -C $dailydir`)
    files = readdir(glob"data/*_primary.jld", dailydir)
    if isempty(files)
        data = nothing # no data?
    else
        length(files) == 1 || warn("Too many primary.jld files for $date; taking one.")
        data = BenchmarkTools.load(files[1], "results")
    end
    rm(joinpath(dailydir, "data"), recursive = true)
    return data
end

function get_daily_summary(date)
    file = joinpath(cachefolder, "$date.json")
    if !isfile(file)
        data = summarize(get_daily_data(date))
        open(file, "w") do io
            JSON.print(io, data)
        end
    end
    return JSON.parse(readstring(file))
end

# take a Vector{Dict{String, Float64}} and turn it into Dict{String, Vector{Float64}}
# but with nesting and nullable
function transpose_daily_summary(data)
    groups = Set{String}()
    for day in data
        isa(day, Dict) && union!(groups, keys(day))
    end

    if isempty(groups)
        output = Float64[ (day === nothing ? NaN : day) for day in data ]
    else
        output = Dict{String, Any}()
        sizehint!(output, length(groups))
        for group in groups
            values = Any[ (isa(day, Dict) ? get(day, group, nothing) : day) for day in data ]
            output[group] = transpose_daily_summary(values)
        end
    end
    return output
end

# take a Dict{String, Dict{String, ...{String, Vector{Float64}}}
# and flatten it into Dict{String, Vector{Float64}} by name-mangling the paths together
flatten_summary(data) = flatten_summary("", data)
flatten_summary(prefix::String, data::Vector{Float64}) = Dict(prefix => data)
function flatten_summary(prefix::String, data::Dict)
    output = Dict{String, Vector{Float64}}()
    for (k, v) in data
        merge!(output, flatten_summary(isempty(prefix) ? k : "$prefix.$k", v))
    end
    return output
end

if false
    today = trunc(now(), Dates.Day)
    until = today - Dates.Day(90)
    headers = String[]
    data = Any[]
    while today > until
        date = datedirname(today)
        push!(headers, date)
        push!(data, get_daily_summary(date))
        today -= Dates.Day(1)
    end
    missing = data .== nothing
    data = transpose_daily_summary(data)
    data = flatten_summary(data)
end
