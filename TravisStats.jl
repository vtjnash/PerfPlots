
using HTTP
using JSON
using Test
using Dates

push!(LOAD_PATH, @__DIR__)
using Check

const json_headers = Dict{String, String}([
    "Accept" => "application/vnd.travis-ci.2+json",
    "Travis-API-Version" => "2",
    ])
const textplain_headers = Dict{String, String}([
    "Accept" => "text/plain",
    "Travis-API-Version" => "2",
    ])
const uriroot = "https://api.travis-ci.org"
const readtimeout = 60
const repo = "/repos/JuliaLang/julia"
const TravisDateFmt = dateformat"yyyy-mm-dd\THH:MM:SS\Z"

do_request(path) = HTTP.get(uriroot * path, headers = json_headers, readtimeout = readtimeout)

test_connection() = @testset "Sanity check" begin
    r = do_request("/")
    @test r.status == 200
    @test r["Content-Type"] == "application/json"
    @test String(r.body) == """{"hello":"world"}"""
    r
end

struct IdIndex
    builds::Dict{Int, Dict{String, Any}}
    commits::Dict{Int, Dict{String, Any}}
    jobs::Dict{Int, Dict{String, Any}}
end
IdIndex() = IdIndex(
    Dict{Int, Dict{String, Any}}(),
    Dict{Int, Dict{String, Any}}(),
    Dict{Int, Dict{String, Any}}())
IdIndex(builds, other::IdIndex) = IdIndex(builds, other.commits, other.jobs)

function make_date(dict, elem)
    datestr = dict[elem]
    if isa(datestr, String) # it's Nullable!
        dict[elem] = parse(DateTime, datestr, TravisDateFmt)
    end
    nothing
end

function get_branch_builds!(state::IdIndex, after::String)
    if isempty(after)
        r = do_request("$repo/builds?event_type=push")
    else
        r = do_request("$repo/builds?event_type=push&after_number=$after")
    end
    @check r.status == 200

    data = JSON.parse(String(r.body))
    commits = data["commits"]
    for commit in commits
        commit_id = commit["id"]::Int
        make_date(commit, "committed_at")
        state.commits[commit_id] = commit
    end
    builds = data["builds"]
    build_id = nothing
    for build in builds
        build_id = build["id"]::Int
        make_date(build, "started_at")
        make_date(build, "finished_at")
        state.builds[build_id] = build
    end
    return build_id
end

function get_branch_builds_until!(state::IdIndex, before::DateTime)
    after = ""
    while true
        after_id = get_branch_builds!(state, after)
        if after_id === nothing || state.builds[after_id]["started_at"] < before
            return
        end
        after = state.builds[after_id]["number"]
    end
end

function filter_branch(state::IdIndex, branch::String)
    builds = filter(state.builds) do (id, build)
        return state.commits[build["commit_id"]]["branch"] == branch
    end
    return IdIndex(builds, state)
end

function map_build(f, state::IdIndex)
    newdict = map(state.builds) do build
        return build.first => f(build.second)
    end
    return newdict
end

function foreach_build(f, state::IdIndex)
    foreach(state.builds) do build
        f(build.second)
    end
end

function fetch_jobs!(state)
    foreach_build(state) do build
        foreach(build["job_ids"]) do job_id
            get!(state.jobs, job_id) do
                job = do_request("/jobs/$job_id")
                @check job.status == 200
                data = JSON.parse(String(job.body))
                return data["job"]
            end
        end
    end
end

const blacklist = Set([338558293, 339157435]) # job_id that are broken (406) on Travis
function fetch_sysimg_size!(state)
    foreach_build(state) do build
        foreach(build["job_ids"]) do job_id
            if !haskey(build, "bytes-linux-x86_64")
                job = state.jobs[job_id]
                job_config = job["config"]
                if job_config["os"] == "linux" && contains(job_config["env"], "x86_64")
                    if job["state"] == "passed" && !in(job_id, blacklist)
                        raw_log = HTTP.get("$uriroot/jobs/$job_id/log", headers = textplain_headers)
                        @check raw_log.status == 200
                        s = String(raw_log.body)
                        m = match(r"\.data\s+(\d+)", s)
                        @check isa(m, RegexMatch)
                        bytes = parse(Int, m[1])
                    else
                        bytes = 0
                    end
                    build["bytes-linux-x86_64"] = bytes
                end
            end
        end
    end
end

function build_stats_bytes(state)
    min_bytes = typemax(Int)
    max_bytes = 0
    foreach_build(state) do build
        bytes = build["bytes-linux-x86_64"]::Int
        if bytes > 0
            min_bytes = min(bytes, min_bytes)
            max_bytes = max(bytes, max_bytes)
        end
    end
    return (min_bytes, max_bytes)
end


if false
    # ulimit -n 8000
    io = STDOUT
    cols = displaysize(io)[2]
    state = IdIndex()
    until = now(Dates.UTC) - Dates.Day(30) # last 30 days
    get_branch_builds_until!(state, until)
    state = filter_branch(state, "master")
    fetch_jobs!(state)
    fetch_sysimg_size!(state)
    min_bytes, max_bytes = build_stats_bytes(state)
    for id in sort(collect(keys(state.builds)))
        bytes = state.builds[id]["bytes-linux-x86_64"]
        commit = state.commits[state.builds[id]["commit_id"]]
        sha = commit["sha"][1:10]
        msg = split(commit["message"], '\n', limit=2)[1][1:min(end, 40)]
        spark = "#" ^ (bytes > 0 ? 1 + cols ÷ 2 * (bytes - min_bytes) ÷ (max_bytes - min_bytes) : 0)
        println(io, "$sha $bytes bytes  $spark    \t$msg")
    end
end
