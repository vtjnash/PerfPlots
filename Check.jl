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
