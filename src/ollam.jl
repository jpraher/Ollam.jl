# ollam.jl
#
# author: Wade Shen
# swade@ll.mit.edu
# Copyright &copy; 2009 Massachusetts Institute of Technology, Lincoln Laboratory
# version 0.1
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
module ollam
using Stage, LIBSVM, SVM, DataStructures, CVX
import Base: copy, start, done, next, length, dot
export LinearModel, copy, score, best, train_perceptron, test_classification, train_svm, train_mira, train_libsvm, lazy_map, indices, print_confusion_matrix, hildreth, setup_hildreth

# ----------------------------------------------------------------------------------------------------------------
# Utilities
# ----------------------------------------------------------------------------------------------------------------
logger = Log(STDERR)

immutable Map{I}
    flt::Function
    itr::I
end
lazy_map(f::Function, itr) = Map(f, itr)

function start(m :: Map) 
  s = start(m.itr)
  return s
end

function next(m :: Map, s) 
  n, ns = next(m.itr, s)
  return (m.flt(n), ns)
end

done(m :: Map, s) = done(m.itr, s)
length(m :: Map) = length(m.itr)

# linear algebra helpers
indices(a::SparseMatrixCSC) = a.rowval
indices(a::Vector)          = 1:length(a)

sqr(a::Vector) = norm(a)^2
function sqr(a::SparseMatrixCSC)
  total = 0.0
  for i in indices(a)
    total += a[i] * a[i]
  end
  return total
end
dot(a::SparseMatrixCSC, b::Vector) = dot(b, a)
dot(a::SparseMatrixCSC, b::Matrix) = dot(b, a)
function dot(a::Union(Vector, SparseMatrixCSC), b::SparseMatrixCSC)
  total = 0.0
  for i in indices(b)
    total += a[i] * b[i]
  end
  return total
end
function dot(a::Matrix, b::SparseMatrixCSC) 
  total = 0.0
  for i in indices(b)
    total += a[1, i] * b[i]
  end
  return total
end
dot(a::Matrix, b::Vector) = (a * b)[1]

function print_confusion_matrix(confmat)
  total, errors = 0, 0

  str = @sprintf("%10s", "")
  for t in keys(confmat)
    str *= @sprintf(" %10s", t)
  end
  @sep logger
  @info logger "$str" * @sprintf(" %10s %10s", "N", "class %")
  
  for t in keys(confmat)
    str = @sprintf("%-10s", t)
    rtotal, rerrors = 0, 0
    for h in keys(confmat)
      str *= @sprintf(" %10d", confmat[t][h])
      if t != h
        rerrors += confmat[t][h]
      end
      rtotal += confmat[t][h]
    end
    errors += rerrors
    total  += rtotal
    @info logger "$str" * @sprintf(" %10d %10.7f", rtotal, 1.0 - rerrors/rtotal)
  end
  @sep logger
  
  @info logger "accuracy = $(1.0 - errors/total)"
  
end

# ----------------------------------------------------------------------------------------------------------------
# Types
# ----------------------------------------------------------------------------------------------------------------
type LinearModel{T}
  weights     :: Matrix{Float64}
  b           :: Vector{Float64}

  class_index :: Dict{T, Int32}
  index_class :: Array{T, 1}
end

dims(lm :: LinearModel)    = size(lm.weights, 2)
classes(lm :: LinearModel) = size(lm.weights, 1)

function LinearModel{T}(classes::Dict{T, Int32}, dims) 
  index = Array(T, length(classes))
  for (k, i) in classes
    index[i] = k
  end

  return LinearModel(zeros(length(index), dims), zeros(length(index)), classes, index)
end

copy(lm :: LinearModel) = LinearModel(copy(lm.weights), copy(lm.b), copy(lm.class_index), copy(lm.index_class))
score(lm :: LinearModel, fv::Vector) = lm.weights * fv + lm.b #[ dot(lm.weights[c, :], fv) + lm.b[c] for c = 1:size(lm.weights, 1) ]
score(lm :: LinearModel, fv::SparseMatrixCSC) = vec(lm.weights * fv + lm.b) #[ dot(lm.weights[c, :], fv) + lm.b[c] for c = 1:size(lm.weights, 1) ]

function best{T <: FloatingPoint}(scores :: Vector{T}) 
  bidx = indmax(scores)
  return bidx, scores[bidx]
end

function test_classification(lm :: LinearModel, fvs, truth; record = (truth, hyp) -> nothing)
  errors = 0
  total  = 0
  
  for (fv, t) in zip(fvs, truth)
    scores  = score(lm, fv)
    bidx, b = best(scores)
    if lm.index_class[bidx] != t
      errors += 1
    end
    record(t, lm.index_class[bidx])
    total += 1
  end

  return errors / total
end

# ----------------------------------------------------------------------------------------------------------------
# Perceptron
# ----------------------------------------------------------------------------------------------------------------
function train_perceptron(fvs, truth, init_model; learn_rate = 1.0, average = true, iterations = 40, log = Log(STDERR))
  model = copy(init_model)
  acc   = LinearModel(init_model.class_index, dims(init_model))

  for i = 1:iterations
    for (fv, t) in zip(fvs, truth)
      scores     = score(model, fv)
      bidx, b    = best(scores)
      if model.index_class[bidx] != t
        for c = 1:classes(model)
          sign = model.index_class[c] == t ? 1.0 : (-1.0 / (classes(model) - 1))
          model.weights[c, :] += sign * learn_rate * fv'
          if average
            acc.weights += model.weights
          end
        end
      end
    end
    @info log @sprintf("iteration %3d complete (Training error rate: %7.3f%%)", i, test_classification(model, fvs, truth) * 100.0)
  end
  
  if average
    acc.weights /= (length(fvs) * iterations)
    return acc
  else
    return model
  end
end

# ----------------------------------------------------------------------------------------------------------------
# MIRA
# ----------------------------------------------------------------------------------------------------------------
function mira_update(weights, bidx, tidx, alpha, fv::SparseMatrixCSC)
  for idx in indices(fv)
    tmp = alpha * fv[idx]
    weights[bidx, idx] -= tmp
    weights[tidx, idx] += tmp
  end
end

function mira_update(weights, bidx, tidx, alpha, fv::Vector)
  tmp = alpha * fv'
  weights[bidx, :] -= tmp
  weights[tidx, :] += tmp
end

type HildrethState
  k           :: Int32
  alpha       :: Vector{Float64}
  F           :: Vector{Float64}
  kkt         :: Vector{Float64}
  C           :: Float64
  A           :: Matrix{Float64}
  is_computed :: Vector{Bool}
  EPS         :: Float64
  ZERO        :: Float64
  MAX_ITER    :: Float64
end

function setup_hildreth(;k = 5, C = 0.1, EPS = 1e-8, ZERO = 0.0000000000000001, MAX_ITER = 10000) # assumes that the number of contraints == number of distances
  alpha       = zeros(k)
  F           = zeros(k)
  kkt         = zeros(k)
  A           = zeros(k, k)
  is_computed = falses(k)
  return HildrethState(k, alpha, F, kkt, C, A, is_computed, EPS, ZERO, MAX_ITER)
end

# translated from Ryan McDonald's MST Parser
function hildreth(a, b, h)
  max_kkt = -Inf
  max_kkt_i = -1

  for i = 1:h.k
    h.A[i, i] = dot(a[i], a[i])
    h.kkt[i] = h.F[i] = b[i]
    h.is_computed[i] = false
    if h.kkt[i] > max_kkt
      max_kkt   = h.kkt[i]
      max_kkt_i = i
    end
    h.alpha[i] = 0.0
  end

  iter = 0
  while max_kkt >= h.EPS && iter < h.MAX_ITER
    diff_alpha = h.A[max_kkt_i, max_kkt_i] <= h.ZERO ? 0.0 : h.F[max_kkt_i] / h.A[max_kkt_i, max_kkt_i]
    try_alpha  = h.alpha[max_kkt_i] + diff_alpha
    add_alpha  = 0.0
    
    if try_alpha < 0.0
      add_alpha = - h.alpha[max_kkt_i]
    elseif try_alpha > h.C
      add_alpha = h.C - h.alpha[max_kkt_i]
    else
      add_alpha = diff_alpha
    end

    h.alpha[max_kkt_i] += add_alpha

    if !h.is_computed[max_kkt_i]
      for i = 1:h.k
	h.A[i, max_kkt_i] = dot(a[i], a[max_kkt_i])
	h.is_computed[max_kkt_i] = true
      end
    end
    for i = 1:h.k
      h.F[i]  -= add_alpha * h.A[i, max_kkt_i]
      h.kkt[i] = h.F[i]
      if h.alpha[i] > (h.C - h.ZERO)
	h.kkt[i] = -h.kkt[i]
      elseif h.alpha[i] > h.ZERO
	h.kkt[i] = abs(h.F[i])
      end
    end		
    max_kkt   = -Inf
    max_kkt_i = -1
    for i = 1:h.k
      if h.kkt[i] > max_kkt 
        max_kkt   = h.kkt[i]
        max_kkt_i = i
      end
    end
    iter += 1
  end

  return h.alpha
end

function train_mira(fvs, truth, init_model; average = true, C = 0.1, k = 1, iterations = 20, lossfn = (a, b) -> a == b ? 0.0 : 1.0, log = Log(STDERR))
  model = copy(init_model)
  acc   = LinearModel(init_model.class_index, dims(init_model))
  numfv = 0

  h       = setup_hildreth(k = min(k, length(model.class_index)), C = C)
  b       = Array(Float64, h.k)
  kidx    = Array(Int32, h.k)
  distvec = Array(Union(SparseMatrixCSC, Vector), h.k)
  
  for i = 1:iterations
    numfv = 0
    alpha = 0.0
    for (fv, t) in zip(fvs, truth)
      scores    = score(model, fv)
      tidx      = model.class_index[t]
      tgt_score = scores[tidx]

      # K-best
      if h.k > 1
        sorted = sortperm(scores, rev = true) #sort([ x for x in enumerate(scores) ], rev = true, by = x -> x[2])
        for n = 1:h.k
          cidx        = sorted[n]
          score       = scores[cidx]
          class       = model.index_class[cidx]
          loss        = lossfn(t, class)
          dist        = tgt_score - score
        
          b[n]       = loss - dist
          distvec[n] = 2 * fv
          kidx[n]    = cidx
        end
        
        alphas = hildreth(distvec, b, h)

        # update
        for n = 1:h.k
          for d in indices(fv)
            model.weights[kidx[n], d] -= alphas[n] * fv[d]
            model.weights[tidx, d]    += alphas[n] * fv[d]
          end
        end
      else
        bidx, b_score = best(scores)
        #@debug logger "truth: $t -- best class $(model.index_class[bidx]) -- best score: $b_score, truth score: $tgt_score"

        # 1-best
        class = model.index_class[bidx]
        loss  = lossfn(t, class)
        dist  = tgt_score - b_score
        alpha = min((loss - dist) / (2 * sqr(fv)), C)

        #@debug logger "loss = $loss, dist = $dist [$tgt_score - $b_score], denom = $(2 * norm(fv)^2), alpha = $alpha"
        mira_update(model.weights, bidx, tidx, alpha, fv)
      end

      if average
        for x = 1:size(acc.weights, 1)
          for y = 1:size(acc.weights, 2)
            acc.weights[x, y] += model.weights[x, y]
          end
        end
      end
      numfv += 1
    end
    @info log @sprintf("iteration %3d complete (Training error rate: %7.3f%%)", i, test_classification(model, fvs, truth) * 100.0)
  end
  
  if average
    acc.weights /= (numfv * iterations)
    return acc
  else
    return model
  end
end

# ----------------------------------------------------------------------------------------------------------------
# SVM
# ----------------------------------------------------------------------------------------------------------------
immutable SVMNode
    index::Int32
    value::Float64
end

immutable SVMModel
  param::LIBSVM.SVMParameter
  nr_class::Int32
  l::Int32
  SV::Ptr{Ptr{LIBSVM.SVMNode}}
  sv_coef::Ptr{Ptr{Float64}}
  rho::Ptr{Float64}
  probA::Ptr{Float64}
  probB::Ptr{Float64}
  sv_indices::Ptr{Int32}

  label::Ptr{Int32}
  nSV::Ptr{Int32}

  free_sv::Int32
end

function transfer_sv(p::Ptr{LIBSVM.SVMNode})
  ret  = (LIBSVM.SVMNode)[]
  head = unsafe_load(p)

  while head.index != -1
    push!(ret, head)
    p += 16
    head = unsafe_load(p)
  end
  return ret
end

function transfer(svm)
  # unpack svm model
  ptr    = unsafe_load(convert(Ptr{SVMModel}, svm.ptr))
  nSV    = pointer_to_array(ptr.nSV, ptr.nr_class)
  xSV    = pointer_to_array(ptr.SV, ptr.l)
  SV     = (Array{LIBSVM.SVMNode, 1})[ transfer_sv(x) for x in xSV ]
  xsvc   = pointer_to_array(ptr.sv_coef, ptr.nr_class)
  svc    = (Array{Float64, 1})[ pointer_to_array(x, ptr.l) for x in xsvc ]
  labels = pointer_to_array(ptr.label, ptr.nr_class)
  rho    = pointer_to_array(ptr.rho, 1)
  @debug logger "# of SVs = $(length(SV)), labels = $labels, rho = $rho, $(svm.labels)"
  
  # precompute classifier weights
  start = 1
  weights = zeros(svm.nfeatures) #Array(Float64, svm.nfeatures)

  for i = 1:ptr.nr_class
    for sv_offset = 0:(nSV[i]-1)
      sv = SV[start + sv_offset]
      for d = 1:length(sv)
        weights[sv[d].index] += svc[1][start + sv_offset] * sv[d].value
      end
    end
    start += nSV[i]
  end
  b = -rho[1]

  if svm.labels[1] == -1
    weights = -weights
    b       = -b
  end

  return (weights, b)
end

function train_libsvm(fvs, truth; C = 1.0, nu = 0.5, cache_size = 200.0, eps = 0.0001, shrinking = true, verbose = false, gamma = 0.5, log = Log(STDERR))
  i = 1
  classes = Dict{Any, Int32}()

  for t in truth
    if !(t in keys(classes))
      classes[t] = i
      i += 1
    end
  end


  feats = hcat(fvs...)
  model = LinearModel(classes, size(feats, 1))

  svms  = Array(Any, length(classes))
  refs  = Array(Any, length(classes))

  for (t, ti) in classes
    @timer logger "training svm for class $t (index: $ti)" begin
      refs[ti] = @spawn begin
        svm_t = svmtrain(map(c -> c == t ? 1 : -1, truth), feats; 
                         gamma = gamma, C = C, nu = nu, kernel_type = int32(0), degree = int32(1), svm_type = int32(0),
                         cache_size = cache_size, eps = eps, shrinking = shrinking, verbose = verbose)
        transfer(svm_t)
      end
    end
  end

  for c = 1:length(refs)
    svms[c] = fetch(refs[c])
  end

  for c = 1:length(svms)
    weights_c, b_c = svms[c]
    for i = 1:length(weights_c)
      model.weights[c, i] = weights_c[i]
    end
    model.b[c] = b_c
  end

  return model # transfer(classes, svms)
end

function train_svm(fvs, truth; C = 0.01, batch_size = -1, iterations = 100)
  i = 1
  classes = Dict{Any, Int32}()

  for t in truth
    if !(t in keys(classes))
      classes[t] = i
      i += 1
    end
  end

  feats = hcat(fvs...)
  if batch_size == -1
    batch_size = size(feats, 2)
  end

  model = LinearModel(classes, size(feats, 1))

  svms  = Array(Any, length(classes))
  refs  = Array(Any, length(classes))

  for (t, ti) in classes
    @timer logger "training svm for class $t (index: $ti)" begin
      refs[ti] = @spawn begin
        svm_t = svm(feats, map(c -> c == t ? 1 : -1, truth);
                    lambda = C, T = iterations, k = batch_size)
        (svm_t.w, 0.0)
      end
    end
  end

  for c = 1:length(refs)
    svms[c] = fetch(refs[c])
  end

  for c = 1:length(svms)
    weights_c, b_c = svms[c]
    for i = 1:length(weights_c)
      model.weights[c, i] = weights_c[i]
    end
    model.b[c] = b_c
  end

  return model # transfer(classes, svms)
end

end # module end
