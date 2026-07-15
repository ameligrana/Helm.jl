abstract type AbstractCommand end

struct Cmds{N,T<:Tuple{Vararg{AbstractCommand,N}}} <: SystemConfig end


Cmds(t::T) where {N,T<:Tuple{Vararg{AbstractCommand,N}}} = Cmds{N,T}()


struct NewEntity{V<:Tuple} <: AbstractCommand end
struct RemoveEntity <: AbstractCommand end
struct AddComponents{C<:Tuple} <: AbstractCommand end
struct RemoveComponents{R<:Tuple} <: AbstractCommand end
struct ExchangeComponents{A<:Tuple,R<:Tuple} <: AbstractCommand end
struct SetComponents{V<:Tuple} <: AbstractCommand end
struct SetRelations{R<:Tuple} <: AbstractCommand end

reads(::Cmds) = ()
writes(::Cmds) = ()
reads(::Type{Cmds}) = ()
writes(::Type{Cmds}) = ()

@generated function to_command_buffer(world::W, ::Cmds{N,T}) where {W<:Ark.World,N,T<:Tuple}
  storage_type = W.parameters[1]
  ark_cmd_types = DataType[]

  for helm_cmd_type in T.parameters
    if helm_cmd_type <: NewEntity
      V = helm_cmd_type.parameters[1]
      val_tuple_type = Tuple{[Val{fieldtype(V, j)} for j in 1:fieldcount(V)]...}
      final_tuple = Ark._spec_value_tuple_type(val_tuple_type, storage_type)
      push!(ark_cmd_types, Ark.NewEntityCommand{final_tuple})

    elseif helm_cmd_type <: RemoveEntity
      push!(ark_cmd_types, Ark.RemoveEntity)

    elseif helm_cmd_type <: AddComponents
      C = helm_cmd_type.parameters[1]
      val_tuple_type = Tuple{[Val{fieldtype(C, j)} for j in 1:fieldcount(C)]...}
      final_tuple = Ark._spec_value_tuple_type(val_tuple_type, storage_type)
      push!(ark_cmd_types, Ark.AddComponentsCommand{final_tuple})

    elseif helm_cmd_type <: RemoveComponents
      R = helm_cmd_type.parameters[1]
      val_tuple_type = Tuple{[Val{fieldtype(R, j)} for j in 1:fieldcount(R)]...}
      final_tuple = Ark._spec_value_tuple_type(val_tuple_type)  # 1-arg method
      push!(ark_cmd_types, Ark.RemoveComponentsCommand{final_tuple})

    elseif helm_cmd_type <: ExchangeComponents
      A = helm_cmd_type.parameters[1]
      R = helm_cmd_type.parameters[2]
      val_tuple_A = Tuple{[Val{fieldtype(A, j)} for j in 1:fieldcount(A)]...}
      final_tuple_A = Ark._spec_value_tuple_type(val_tuple_A, storage_type)
      val_tuple_R = Tuple{[Val{fieldtype(R, j)} for j in 1:fieldcount(R)]...}
      final_tuple_R = Ark._spec_value_tuple_type(val_tuple_R)  # 1-arg for remove part
      push!(ark_cmd_types, Ark.ExchangeComponentsCommand{final_tuple_A,final_tuple_R})

    elseif helm_cmd_type <: SetComponents
      V = helm_cmd_type.parameters[1]
      val_tuple_type = Tuple{[Val{fieldtype(V, j)} for j in 1:fieldcount(V)]...}
      final_tuple = Ark._spec_value_tuple_type(val_tuple_type)   # 1-arg method
      push!(ark_cmd_types, Ark.SetComponentsCommand{final_tuple})

    elseif helm_cmd_type <: SetRelations
      R = helm_cmd_type.parameters[1]
      final_tuple = Ark._spec_relations_tuple_type(R)   # does not need Val-wrapping
      push!(ark_cmd_types, Ark.SetRelationsCommand{final_tuple})
    end
  end

  C = length(ark_cmd_types) == 1 ? ark_cmd_types[1] : Union{ark_cmd_types...}
  return quote
    return Ark.CommandBuffer{$W,$C}(world, Vector{$C}())
  end
end


@inline @generated function _valtuple(t::Tuple{Vararg{Any,N}}) where {N}
  exprs = Expr[:(Val(getfield(t, $i))) for i in 1:N]
  return Expr(:tuple, exprs...)
end

_val_parameter(::Type{Val{T}}) where {T} = T

function _extract_component_types(VT::Type{<:Tuple})
  component_types = ntuple(i -> _val_parameter(fieldtype(VT, i)), Val(fieldcount(VT)))
  return Tuple{component_types...}
end


function _spec_command_type(spec::Tuple{typeof(Ark.new_entity!),T}) where {T<:Tuple}
  val_tuple = _valtuple(spec[2])            # (Val{Int}(), Val{Float64}())
  VT = typeof(val_tuple)                    # Tuple{Val{Int}, Val{Float64}}
  return NewEntity{_extract_component_types(VT)}
end

_spec_command_type(::Tuple{typeof(Ark.remove_entity!)}) = RemoveEntity

function _spec_command_type(spec::Tuple{typeof(Ark.add_components!),T}) where {T<:Tuple}
  val_tuple = _valtuple(spec[2])
  VT = typeof(val_tuple)
  return AddComponents{_extract_component_types(VT)}
end

function _spec_command_type(spec::Tuple{typeof(Ark.remove_components!),T}) where {T<:Tuple}
  val_tuple = _valtuple(spec[2])
  VT = typeof(val_tuple)
  return RemoveComponents{_extract_component_types(VT)}
end

function _spec_command_type(
  spec::Tuple{typeof(Ark.exchange_components!),NamedTuple{(:add, :remove),<:Tuple{A,R}}}
) where {A<:Tuple,R<:Tuple}
  add_val_tuple = _valtuple(spec[2].add)
  remove_val_tuple = _valtuple(spec[2].remove)
  VT_add = typeof(add_val_tuple)
  VT_rem = typeof(remove_val_tuple)
  return ExchangeComponents{_extract_component_types(VT_add),_extract_component_types(VT_rem)}
end

function _spec_command_type(spec::Tuple{typeof(Ark.set_components!),T}) where {T<:Tuple}
  val_tuple = _valtuple(spec[2])
  VT = typeof(val_tuple)
  return SetComponents{_extract_component_types(VT)}
end

function _spec_command_type(spec::Tuple{typeof(Ark.set_relations!),T}) where {T<:Tuple}
  val_tuple = _valtuple(spec[2])
  VT = typeof(val_tuple)
  # set_relations! expects relation types directly, no wrapping
  return SetRelations{_extract_component_types(VT)}
end

_spec_command_type(x) = throw(ArgumentError("unknown command specification: $x"))


function _specs_to_types(specs::Tuple)
  n == 0 && throw(
    ArgumentError("command buffer needs to contain at least one deferred operation")
  )

  types = Vector{Type}(undef, length(specs))

  @inbounds for i in eachindex(specs)
    types[i] = _spec_command_type(specs[i])
  end

  return Tuple(types)
end

function Cmds(specs::Tuple)
  n = length(specs)

  n == 0 && throw(
    ArgumentError("command buffer needs to contain at least one deferred operation")
  )

  types = Vector{Type}(undef, n)

  @inbounds for i in eachindex(specs)
    types[i] = _spec_command_type(specs[i])
  end

  T = Tuple{types...}

  return Cmds{n,T}()
end
