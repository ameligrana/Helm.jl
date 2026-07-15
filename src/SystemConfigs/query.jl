struct QueryData{R,W,WI,WO} <: SystemConfig end
struct Const{T} end

Const(::Type{T}) where {T} = Const{T}

_unwrap_comp(::Type{T}) where {T} = (T, :write)
_unwrap_comp(::Type{Const{T}}) where {T} = (T, :read)

_sort_comps(::Tuple{}, reads::Tuple, writes::Tuple) = (reads, writes)

function _sort_comps(comps::Tuple, reads::Tuple, writes::Tuple)
  head = comps[1]
  tail = Base.tail(comps)

  T, mode = _unwrap_comp(head)

  if mode === :read
    return _sort_comps(tail, (reads..., T), writes)
  else
    return _sort_comps(tail, reads, (writes..., T))
  end
end

function separate_reads_and_writes(comps::Tuple)
  return _sort_comps(comps, (), ())
end

function Query(comps::Tuple; with=(), without=())
  R, W = separate_reads_and_writes(comps)
  return QueryData{Tuple{R...},Tuple{W...},Tuple{with...},Tuple{without...}}()
end

@generated function Ark.Query(
  w::Ark.World,
  ::QueryData{R_Tuple,W_Tuple,WI_Tuple,WO_Tuple}
) where {
  R_Tuple<:Tuple,
  W_Tuple<:Tuple,
  WI_Tuple<:Tuple,
  WO_Tuple<:Tuple,
}
  r_types = map(T -> Ark.Const{T}, R_Tuple.parameters)
  w_types = W_Tuple.parameters
  wi_types = WI_Tuple.parameters
  wo_types = WO_Tuple.parameters

  comp_types = (r_types..., w_types...)

  return :(Ark.Query(w, $comp_types; with=$((wi_types...,)), without=$((wo_types...,))))
end

reads(::QueryData{R,W,WI,WO}) where {R,W,WI,WO} = R
writes(::QueryData{R,W,WI,WO}) where {R,W,WI,WO} = W

reads(::Type{QueryData{R,W,WI,WO}}) where {R,W,WI,WO} = R.parameters
writes(::Type{QueryData{R,W,WI,WO}}) where {R,W,WI,WO} = W.parameters
