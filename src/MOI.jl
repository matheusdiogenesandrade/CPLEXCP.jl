# Inspired by CPLEX.jl.

@enum(
    VariableType,
    CONTINUOUS,
    BINARY,
    INTEGER,
    # SEMIINTEGER, # TODO: Only for IloMPModeler; useful to support?
    # SEMICONTINUOUS, # TODO: Only for IloMPModeler; useful to support?
    INTERVAL,
    SEQUENCEINTERVAL
)

mutable struct VariableInfo
    index::MOI.VariableIndex
    variable::Variable
    name::String
    type::VariableType

    VariableInfo(index::MOI.VariableIndex, variable::Variable) = new(index, variable, "", CONTINUOUS)
end

mutable struct ConstraintInfo
    index::MOI.ConstraintIndex
    constraint::Constraint
    set::MOI.AbstractSet
    name::String

    ConstraintInfo(index::MOI.ConstraintIndex, constraint::Constraint, set::MOI.AbstractSet) = new(index, constraint, set, "")
end

mutable struct Optimizer <: MOI.AbstractOptimizer
    # The low-level CPLEX model.
    inner::JavaCPOModel

    # The model name.
    name::String

    # A flag to keep track of MOI.Silent, which overrides the OutputFlag
    # parameter.
    silent::Bool

    # A mapping from the MOI.VariableIndex to the CPLEX variable object.
    # VariableInfo also stores some additional fields like the type of variable.
    variable_info::CleverDicts.CleverDict{MOI.VariableIndex, VariableInfo}

    # A mapping from the MOI.ConstraintIndex to the CPLEX variable object.
    # VariableInfo also stores some additional fields like the type of variable.
    constraint_info::Dict{MOI.ConstraintIndex, ConstraintInfo}

    # Memorise the objective sense and the function separately, as the Concert
    # API forces to give both at the same time.
    objective_sense::OptimizationSense
    objective_function_cp::Union{Nothing, NumExpr}
    objective_cp::Union{Nothing, IloObjective}

    # # Mappings from variable and constraint names to their indices. These are
    # # lazily built on-demand, so most of the time, they are `nothing`.
    # name_to_variable::Union{Nothing, Dict{String, Union{Nothing, MOI.VariableIndex}}}
    # name_to_constraint_index::Union{Nothing, Dict{String, Union{Nothing, MOI.ConstraintIndex}}}
    # # TODO: Or rather use the solver's functionalities?

    """
        Optimizer()

    Create a new Optimizer object.
    """
    function Optimizer()
        model = new()
        model.inner = cpo_java_model()

        # TODO: set the solver to silent.
        # MOI.set(model, MOI.RawParameter("CPXPARAM_ScreenOutput"), 1)
        model.silent = false

        model.variable_info = CleverDicts.CleverDict{MOI.VariableIndex, VariableInfo}()
        model.constraint_info = CleverDicts.CleverDict{MOI.ConstraintIndex, VariableInfo}()
        model.objective_sense = MOI.FEASIBILITY_SENSE
        model.objective_function = nothing

        MOI.empty!(model)
        return model
    end
end

# TODO: ?
# Base.show(io::IO, model::Optimizer) = show(io, model.inner)

function MOI.empty!(model::Optimizer)
    model.inner = cpo_java_model()
    model.name = ""
    # if model.silent
    #     MOI.set(model, MOI.RawParameter("CPXPARAM_ScreenOutput"), 0)
    # end
    empty!(model.variable_info)
    empty!(model.constraint_info)
    model.objective_sense = MOI.FEASIBILITY_SENSE
    model.objective_function = nothing
    return
end


function MOI.is_empty(model::Optimizer)
    !isempty(model.name) && return false
    !isempty(model.variable_info) && return false
    !isempty(model.constraint_info) && return false
    model.objective_sense != MOI.FEASIBILITY_SENSE && return false
    model.objective_function !== nothing && return false
    return true
end

MOI.get(::Optimizer, ::MOI.SolverName) = "CPLEX CP Optimizer"

## Types of objectives and constraints that are supported.
# TODO: everything CP.

function MOI.supports(
    ::Optimizer,
    ::MOI.ObjectiveFunction{F}
) where {F <: Union{
    MOI.SingleVariable,
    MOI.ScalarAffineFunction{Float64},
    MOI.ScalarQuadraticFunction{Float64}
}}
    return true
end

function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.SingleVariable}, ::Type{F}
) where {F <: Union{
    MOI.EqualTo{Float64},
    MOI.LessThan{Float64},
    MOI.GreaterThan{Float64},
    MOI.Interval{Float64},
    MOI.EqualTo{Int}, # TODO: Int (platform-dependent) or Int64?
    MOI.LessThan{Int},
    MOI.GreaterThan{Int},
    MOI.Interval{Int}
    # No ZeroOne or Integer, this is supposed to be done when creating a variable.
}}
    return true
end

function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.ScalarAffineFunction{Float64}}, ::Type{F}
) where {F <: Union{
    MOI.EqualTo{Float64},
    MOI.LessThan{Float64},
    MOI.GreaterThan{Float64},
    MOI.Interval{Float64},
    MOI.EqualTo{Int},
    MOI.LessThan{Int},
    MOI.GreaterThan{Int},
    MOI.Interval{Int}
}}
    return true
end

function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.ScalarQuadraticFunction{Float64}}, ::Type{F}
) where {F <: Union{
    MOI.EqualTo{Float64},
    MOI.LessThan{Float64},
    MOI.GreaterThan{Float64},
    MOI.Interval{Float64},
    MOI.EqualTo{Int},
    MOI.LessThan{Int},
    MOI.GreaterThan{Int},
    MOI.Interval{Int}
}}
    return true
end

MOI.supports(::Optimizer, ::MOI.VariableName, ::Type{MOI.VariableIndex}) = true
MOI.supports(::Optimizer, ::MOI.ConstraintName, ::Type{<:MOI.ConstraintIndex}) = true

# TODO: supports attributes (not implemented in lower-level API for now).

# It is possible to use the default copy behaviour, including with names.
MOI.Utilities.supports_default_copy_to(::Optimizer, ::Bool) = true

function MOI.copy_to(dest::Optimizer, src::MOI.ModelLike; kwargs...)
    return MOI.Utilities.automatic_copy_to(dest, src; kwargs...)
end

function MOI.get(model::Optimizer, ::MOI.ListOfVariableAttributesSet)
    return MOI.AbstractVariableAttribute[MOI.VariableName()]
end

function MOI.get(model::Optimizer, ::MOI.ListOfModelAttributesSet)
    attributes = Any[MOI.ObjectiveSense()]
    typ = MOI.get(model, MOI.ObjectiveFunctionType())
    if typ !== nothing
        push!(attributes, MOI.ObjectiveFunction{typ}())
    end
    if MOI.get(model, MOI.Name()) != ""
        push!(attributes, MOI.Name())
    end
    return attributes
end

function MOI.get(model::Optimizer, ::MOI.ListOfConstraintAttributesSet)
    return MOI.AbstractConstraintAttribute[MOI.ConstraintName()]
end

## Variables
# Don't implement add_variable[s]: this does not give enough information to
# call the underlying API.

function _info(model::Optimizer, key::MOI.VariableIndex)
    if haskey(model.variable_info, key)
        return model.variable_info[key]
    end
    throw(MOI.InvalidIndex(key))
end

function _make_var(model::Optimizer, variable::Variable, set::MOI.AbstractScalarSet)
    # Initialize `VariableInfo` with a dummy `VariableIndex` and a column,
    # because we need `add_item` to tell us what the `VariableIndex` is.
    index = CleverDicts.add_item(model.variable_info, VariableInfo(MOI.VariableIndex(0), 0))
    info = _info(model, index)
    info.index = index
    info.variable = variable
    return index, MOI.ConstraintIndex{MOI.SingleVariable, typeof(set)}(index)
end

function _make_vars(model::Optimizer, variables::Vector{Variable}, sets::Vector{<:MOI.AbstractScalarSet})
    # Unused, because add_constrained_variables may have variable sets (except for AbstractVectorSet).
    indices = Vector{MOI.VariableIndex}(undef, length(sets))
    cindices = Vector{MOI.ConstraintIndex}(undef, length(sets))
    for i in 1:length(sets)
        indices[i], cindices[i] = _make_var(model, variables[i], sets[i])
    end
    return indices, cindices
end

function _make_numvar(model::Optimizer, set::AbstractScalarSet; lb::Float64=-IloInfinity, ub::Float64=IloInfinity)
    return _make_var(model, cpo_java_numvar(model.inner, lb, ub))
end

function _make_intvar(model::Optimizer, set::AbstractScalarSet; lb::Int=-IloMinInt, ub::Int=IloMaxInt)
    return _make_var(model, cpo_java_intvar(model.inner, lb, ub))
end

function _make_boolvar(model::Optimizer, set::AbstractScalarSet)
    return _make_var(model, cpo_java_boolvar(model.inner))
end

function supports_add_constrained_variables(::Optimizer, ::Type{F}) where {F <: Union{
    MOI.EqualTo{Float64},
    MOI.LessThan{Float64},
    MOI.GreaterThan{Float64},
    MOI.Interval{Float64},
    MOI.EqualTo{Int},
    MOI.LessThan{Int},
    MOI.GreaterThan{Int},
    MOI.Interval{Int},
    MOI.ZeroOne,
    MOI.Integer
}}
    return true
end

function MOI.add_constrained_variable(model::Optimizer, set::MOI.GreaterThan{T}) where {T <: Real}
    return _make_numvar(model, set, lb=set.lower)
end

function MOI.add_constrained_variable(model::Optimizer, set::MOI.LessThan{T}) where {T <: Real}
    return _make_numvar(model, set, lb=set.upper)
end

function MOI.add_constrained_variable(model::Optimizer, set::MOI.EqualTo{T}) where {T <: Real}
    return _make_numvar(model, set, lb=set.value, ub=set.value)
end

function MOI.add_constrained_variable(model::Optimizer, set::MOI.Interval{T}) where {T <: Real}
    return _make_numvar(model, set, lb=set.lower, ub=set.upper)
end

function MOI.add_constrained_variable(model::Optimizer, set::MOI.GreaterThan{T}) where {T <: Integer}
    return _make_intvar(model, set, lb=set.lower)
end

function MOI.add_constrained_variable(model::Optimizer, set::MOI.LessThan{T}) where {T <: Integer}
    return _make_intvar(model, set, lb=set.upper)
end

function MOI.add_constrained_variable(model::Optimizer, set::MOI.EqualTo{T}) where {T <: Integer}
    return _make_intvar(model, set, lb=set.value, ub=set.value)
end

function MOI.add_constrained_variable(model::Optimizer, set::MOI.Interval{T}) where {T <: Integer}
    return _make_intvar(model, set, lb=set.lower, ub=set.upper)
end

function MOI.add_constrained_variable(model::Optimizer, set::MOI.ZeroOne)
    return _make_boolvar(model, set)
end

function MOI.add_constrained_variable(model::Optimizer, set::MOI.Integer)
    return _make_intvar(model, set)
end

function MOI.is_valid(model::Optimizer, v::MOI.VariableIndex)
    return haskey(model.variable_info, v)
end

# TODO: how to implement delete()?
# TODO: implement getting variable from name? MOI.get(model::Optimizer, ::Type{MOI.VariableIndex}, name::String)

function MOI.get(model::Optimizer, ::MOI.VariableName, v::MOI.VariableIndex)
    return _info(model, v).name
end

function MOI.set(
    model::Optimizer, ::MOI.VariableName, v::MOI.VariableIndex, name::String
)
    info = _info(model, v)
    info.name = name
    cpo_java_addable_setname(model.inner.cp, info.variable, name)
    # model.name_to_variable = nothing
    return
end

## Expression parsing (not part of MOI API)

function _parse(model::Optimizer, expr)
    error("_parse not yet implemented for type: $(typeof(expr))")
end

function _parse(model::Optimizer, f::MOI.SingleVariable)
    # A Concert Variable is already an expression.
    return _info(model, f.variable).variable
end

function _parse(model::Optimizer, terms::Vector{MOI.ScalarAffineTerm{T}}) where {T <: Integer}
    cp = model.inner.cp
    coeffs = T[t.coefficient for t in terms.terms]
    vars = NumVar[_info(model, t.variable_index).variable for t in terms.terms]
    return cpo_java_scalprod(cp, coeffs, vars)
end

function _parse(model::Optimizer, f::MOI.ScalarAffineFunction{T}) where {T <: Integer}
    f = MOI.Utilities.canonical(f)
    e = _parse(model, f.terms)
    if !iszero(f.constant)
        cp = model.inner.cp
        e = cpo_java_sum(cp, e, cpo_java_constant(cp, f.constant))
    end
    return e
end

function _parse(model::Optimizer, f::MOI.ScalarQuadraticFunction{T}) where {T <: Integer}
    f = MOI.Utilities.canonical(f)
    cp = model.inner.cp
    e = _parse(model, f.quadratic_terms)
    if length(f.affine_terms) > 0
        e = cpo_java_sum(cp, e, _parse(model, f.affine_terms))
    end
    if !iszero(f.constant)
        e = cpo_java_sum(cp, e, cpo_java_constant(cp, f.constant))
    end
end

## Objective
# TODO: what about @objective(m, Max, count(x .== 1))? Automatically add a constraint (i.e. bridge)? And/or support the constraint as a function?

function _update_objective(model::Optimizer)
    # If the sense is feasibility and there is an internal Concert objective, remove it.
    # Otherwise, this is an optimisation problem.
    if model.objective_sense == MOI.FEASIBILITY_SENSE && model.objective_cp !== nothing
        cpo_java_remove(model.inner.cp, model.objective_cp)
        model.objective_cp = nothing
    end

    # If only no function is available, don't do anything.
    if model.objective_function_cp === nothing
        return
    end

    # Set the new objective.
    if model.objective_sense == MOI.MIN_SENSE
        cpo_java_minimize(model.inner.cp, model.objective_function_cp)
    else
        cpo_java_maximize(model.inner.cp, model.objective_function_cp)
    end
end

function MOI.set(model::Optimizer, ::MOI.ObjectiveSense, sense::MOI.OptimizationSense)
    model.objective_sense = sense
    _update_objective(model)
    return
end

function MOI.get(model::Optimizer, ::MOI.ObjectiveSense)
    return model.objective_sense
end

function MOI.set(
    model::Optimizer, ::MOI.ObjectiveFunction{F}, f::F
) where {F <: MOI.SingleVariable}
    MOI.set(
        model,
        MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
        convert(MOI.ScalarAffineFunction{Float64}, f)
    )
    model.objective_type = SINGLE_VARIABLE
    return
end

function MOI.get(model::Optimizer, ::MOI.ObjectiveFunction{F}) where {F <: AbstractScalarFunction}
    if model.objective_function <: T
        return model.objective_function
    else
        error("Unable to get objective function. Current objective: $(model.objective_function).")
    end
end

function MOI.set(model::Optimizer, ::MOI.ObjectiveFunction{F}, f::F) where {F <: AbstractScalarFunction}
    model.objective_function_cp = _parse(f)
    _update_objective(model)
    return
end

# TODO: modifications. Easy to do, as we have a pointer on the Concert expression!
# function MOI.modify(
#     model::Optimizer,
#     ::MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}},
#     chg::MOI.ScalarConstantChange{Float64}
# )
#     CPLEX.c_api_chgobjoffset(model.inner, chg.new_constant)
#     return
# end
