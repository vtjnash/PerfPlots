
using HTTP
using Requests
using JSON
using Base.Test

const json_headers = Dict{String, String}("Accept" => "application/vnd.travis-ci.2+json")
const textplain_headers = Dict{String, String}("Accept" => "text/plain")
const uriroot = "https://api.travis-ci.org"
const readtimeout = 60.0
const repo = "/repos/JuliaLang/julia"
const TravisDateFmt = dateformat"yyyy-mm-dd\THH:MM:SS\Z"

do_request(path) = HTTP.get(uriroot * path, headers = json_headers, readtimeout = readtimeout)

module Check
    export @check

    struct FailedCheck
        result
        ex
        meta
        FailedCheck(r::ANY, e::ANY, m::ANY) = new(r, e, m)
    end

    @noinline function check_fail(result::ANY, orig_ex::ANY)
        throw(FailedCheck(result, orig_ex, nothing))
    end

    @noinline function check_expr_fail(result::ANY, orig_ex::Expr, values::ANY)
        throw(FailedCheck(result, orig_ex, values))
    end

    function Base.show(io::IO, check::FailedCheck)
        println(io, "FailedCheck(")
        if check.result === false
            println(io, "! ")
            show(io, check.ex)
        else
            show(io, check.ex)
            print(io, " => ")
            show(io, check.result)
            print(io, ")")
        end
    end

    function Base.showerror(io::IO, check::FailedCheck)
        println(io, "Code check failed:")
        println(io, "Expression: ", check.ex)
        if !(check.result === false)
            println(io, " Got: ", check.result)
        end
        if !(check.meta === nothing)
            println(io, " Evaluated: ", check.meta)
        end
    end

    # An internal function, called by the code generated by the @check
    # macro to get results of the test expression.
    # In the special case of a comparison, e.g. x == 5, generate code to
    # evaluate each term in the comparison individually so the results
    # can be displayed nicely.
    function get_test_result(ex::Expr)
        # Normalize non-dot comparison operator calls to :comparison expressions
        if ex.head == :call && length(ex.args) == 3 &&
            first(string(ex.args[1])) != '.' &&
            (ex.args[1] === :(==) || Base.operator_precedence(ex.args[1]) == Test.comparison_prec)
            return get_test_result(Expr(:comparison, ex.args[2], ex.args[1], ex.args[3]))
        end

        if (ex.head == :comparison || ex.head == :call)
            # move all terms of the call into SSA position
            nterms = length(ex.args)
            argret = Expr(:tuple)
            newex = Expr(ex.head)
            testret = Expr(:block)
            resize!(argret.args, nterms)
            resize!(newex.args, nterms)
            resize!(testret.args, nterms + 1)
            for i = 1:nterms
                flatex = ex.args[i]
                argsym = gensym()
                if isa(flatex, Expr)
                    flatex, argvals = get_test_result(flatex)
                    push!(argvals.args, argsym)
                else
                    flatex = esc(flatex)
                    argvals = argsym
                end
                argret.args[i] = argvals
                testret.args[i] = Expr(:(=), argsym, flatex)
                newex.args[i] = argsym
            end
            testret.args[nterms + 1] = newex
            return testret, argret
        end
        return esc(ex), Expr(:tuple)
    end

    macro check(ex::Symbol)
        orig_ex = Expr(:inert, ex)
        return quote
            if (result = $ex) !== true
                check_fail(result, $orig_ex)
            end
        end
    end

    macro check(expr::Expr, kws...)
        # my lazy error checking
        # something between an enhanced @assert
        # and a less-fancy @test
        Test.test_expr!("@test", expr, kws...)
        orig_expr = Expr(:inert, expr)
        resultexpr, valsexpr = get_test_result(expr)
        return quote
            let result = $resultexpr
                if result !== true
                    let values = $valsexpr
                        check_expr_fail(result, $orig_expr, values)
                    end
                end
            end
        end
    end
end
using .Check

test_connection() = @testset "Sanity check" begin
    r = do_request("/")
    @test HTTP.status(r) == 200
    @test HTTP.headers(r)["Content-Type"] == "application/json"
    @test HTTP.string(r) == """{"hello":"world"}"""
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
    @check HTTP.status(r) == 200

    data = JSON.parse(string(r))
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
    builds = filter(state.builds) do id, build
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
                @check HTTP.status(job) == 200
                data = JSON.parse(string(job))
                return data["job"]
            end
        end
    end
end

function fetch_sysimg_size!(state)
    foreach_build(state) do build
        foreach(build["job_ids"]) do job_id
            if !haskey(build, "bytes-linux-x86_64")
                job = state.jobs[job_id]
                job_config = job["config"]
                if job_config["os"] == "linux" && contains(job_config["env"], "x86_64")
                    if job["state"] == "passed"
                        raw_log = Requests.get("$uriroot/jobs/$job_id/log", headers = textplain_headers) # HTTP can't handle this?
                        @check Requests.statuscode(raw_log) == 200
                        s = String(raw_log)
                        m = match(r"(?:\.rodata|__const)\s+(\d+)", s)
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
    until = now(Dates.UTC) - Dates.Day(90) # last 30 days
    get_branch_builds_until!(state, until)
    state = filter_branch(state, "master")
    fetch_jobs!(state)
    fetch_sysimg_size!(state)
    min_bytes, max_bytes = build_stats_bytes(state)
    for id in sort(collect(keys(state.builds)))
        bytes = state.builds[id]["bytes-linux-x86_64"]
        commit = state.commits[state.builds[id]["commit_id"]]
        sha = commit["sha"]
        spark = "#" ^ (bytes > 0 ? 1 + cols ÷ 2 * (bytes - min_bytes) ÷ (max_bytes - min_bytes) : 0)
        println("#$id sha $sha $bytes bytes  $spark")
    end
end