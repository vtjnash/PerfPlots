
using HTTP
using Test
using JSON
using Dates

push!(LOAD_PATH, @__DIR__)
using Check

const uriroot = "https://ci.appveyor.com/api"
const readtimeout = 60
const repo = "/projects/JuliaLang/julia"
const AVDateFmt = dateformat"yyyy-mm-dd\THH:MM:SS"

do_request(path) = HTTP.get(uriroot * path, readtimeout = readtimeout)

@testset "Sanity check" begin
    r = do_request("/")
    @test r.status == 200
    @test r["Content-Type"] == "text/html; charset=utf-8"
    @test !isempty(String(r.body))
    r
end

parsetime(dt::String) = parse(DateTime, split(dt, '.')[1], AVDateFmt)

if true
    startfrom = 20355614
    #startfrom = 16075280
    #startfrom = 8937222
    nrecords = 1000
    while nrecords > 0
        r = do_request("$repo/history?recordsNumber=$(min(nrecords, 100))&startBuildId=$startfrom")
        history = JSON.parse(String(r.body))
        @show history["builds"][1]["buildId"]
        for job in history["builds"]
            job["status"] == "failed" || continue
            "pullRequestId" in keys(job) && continue
            started = parsetime(job["started"])
            finished = parsetime(job["finished"])
            elapsed = finished - started
            if elapsed > Hour(3)
                @show started
                @show job["buildId"]
                println(job)
                println()
            end
        end
        global startfrom = history["builds"][end]["buildId"]
    end
    @show startfrom
end
