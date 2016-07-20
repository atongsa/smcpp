from __future__ import absolute_import, division, print_function
cimport numpy as np
from cython.operator cimport dereference as deref, preincrement as inc
import random
import sys
import numpy as np
import collections
import scipy.optimize
import collections
import wrapt
import six
from ad import adnumber, ADF

from . import logging

init_eigen();
logger = logging.getLogger(__name__)

abort = False
cdef void logger_cb(const char* name, const char* level, const char* message) with gil:
    global abort
    name_s = name.decode("UTF-8")
    level_s = level.decode("UTF-8")
    message_s = message.decode("UTF-8")
    try:
        lvl = {"INFO": logging.INFO, "DEBUG": logging.DEBUG - 1, "DEBUG1": logging.DEBUG,
               "CRITICAL": logging.CRITICAL, "WARNING": logging.WARNING}
        logging.getLogger(name_s).log(lvl[level_s.upper()], message_s)
    except KeyboardInterrupt:
        logging.getLogger(name_s).critical("Aborting")
        abort = True

def _check_abort():
    if abort:
        raise KeyboardInterrupt()

init_logger_cb(logger_cb);

# Everything needs to be C-order contiguous to pass in as
# flat arrays
aca = np.ascontiguousarray

cdef ParameterVector make_params(model):
    cdef ParameterVector ret
    cdef vector[adouble] r
    a = model.stepwise_values()
    dlist = model.dlist
    for aa in a:
        if not isinstance(aa, ADF):
            aa = adnumber(aa)
        r.push_back(double_vec_to_adouble(aa.x, [aa.d(da) for da in dlist]))
    ret.push_back(r)
    cdef vector[adouble] cs
    for ss in model.s:
        cs.push_back(adouble(ss))
    ret.push_back(cs)
    return ret

cdef _make_em_matrix(vector[pMatrixD] mats):
    cdef double[:, ::1] v
    ret = []
    for i in range(mats.size()):
        m = mats[i][0].rows()
        n = mats[i][0].cols()
        ary = aca(np.zeros([m, n]))
        v = ary
        store_matrix(mats[i][0], &v[0, 0])
        ret.append(ary)
    return ret

cdef object _adouble_to_ad(const adouble x, dlist):
    if len(dlist) == 0:
        return x.value()
    r = adnumber(x.value())
    cdef double[::1] vjac
    jac = aca(np.zeros([len(dlist)]))
    vjac = jac
    fill_jacobian(x, &vjac[0])
    for i, d in enumerate(dlist):
        r.d()[d] = jac[i]
    return r

cdef _store_admatrix_helper(Matrix[adouble] &mat, dlist):
    nder = len(dlist)
    m = mat.rows()
    n = mat.cols()
    cdef int i
    cdef int j
    ary = aca(np.zeros([m, n]))
    for i in range(m):
        for j in range(n):
            ary[i, j] = _adouble_to_ad(mat(i, j), dlist)
    return ary

def validate_observation(ob):
    if np.isfortran(ob):
        raise ValueError("Input arrays must be C-ordered")
    if np.any(np.logical_and(ob[:, 1] == 2, ob[:, 2] == ob[:, 3])):
        raise RuntimeError("Error: data set contains sites where every individual is homozygous recessive. "
                "Please encode / fold these as non-segregating (homozygous dominant).")

cdef class _PyInferenceManager:
    cdef int _num_hmms
    cdef object _observations, _model, _theta, _rho
    cdef public long long seed
    cdef vector[double] _hs
    cdef vector[int] _Ls
    cdef InferenceManager* _im
    cdef vector[int*] _obs_ptrs

    def __my_cinit__(self, observations, hidden_states):
        self.seed = 1
        cdef int[:, ::1] vob
        if len(observations) == 0:
            raise RuntimeError("Observations list is empty")
        self._observations = observations
        Ls = []
        ## Validate hidden states
        if any([not np.all(np.sort(hidden_states) == hidden_states),
            hidden_states[0] != 0., hidden_states[-1] != np.inf]):
            raise RuntimeError("Hidden states must be in ascending order with hs[0]=0 and hs[-1] = infinity")
        for ob in observations:
            validate_observation(ob)
            vob = ob
            self._obs_ptrs.push_back(&vob[0, 0])
            Ls.append(ob.shape[0])
        self._num_hmms = len(observations)
        self._hs = hidden_states
        self._Ls = Ls
        _check_abort()

    def __dealloc__(self):
        del self._im

    property folded:
        def __get__(self):
            return self._im.folded

        def __set__(self, bint f):
            self._im.folded = f

    property observations:
        def __get__(self):
            return self._observations

    property theta:
        def __get__(self):
            return self._theta

        def __set__(self, theta):
            self._theta = theta
            self._im.setTheta(theta)

    property rho:
        def __get__(self):
            return self._rho

        def __set__(self, rho):
            self._rho = rho
            self._im.setRho(rho)


    def E_step(self, forward_backward_only=False):
        cdef bool fbOnly = forward_backward_only
        with nogil:
            self._im.Estep(fbOnly)
        _check_abort()

    property model:
        def __get__(self):
            return self._model
        def __set__(self, model):
            self._model = model
            cdef ParameterVector params = make_params(model)
            with nogil:
                self._im.setParams(params)

    property save_gamma:
        def __get__(self):
            return self._im.saveGamma
        def __set__(self, bint sg):
            self._im.saveGamma = sg

    property hidden_states:
        def __get__(self):
            return self._im.hidden_states
        def __set__(self, hs):
            self._im.hidden_states = hs

    # property emission_probs:
    #     def __get__(self):
    #         cdef map[block_key, Vector[adouble]] ep = self._im.getEmissionProbs()
    #         cdef map[block_key, Vector[adouble]].iterator it = ep.begin()
    #         cdef pair[block_key, Vector[adouble]] p
    #         ret = {}
    #         while it != ep.end():
    #             p = deref(it)
    #             key = [0] * 3
    #             for i in range(3):
    #                 key[i] = p.first[i]
    #             M = p.second.size()
    #             v = np.zeros(M)
    #             if self._model.dlist:
    #                 dv = np.zeros([M, len(self._model.dlist)])
    #             for i in range(M):
    #                 v[i] = p.second(i).value()
    #                 for j in range(len(self._model.dlist)):
    #                     dv[i, j] = p.second(i).derivatives()(j)
    #             ret[tuple(key)] = (v, dv) if len(self._model.dlist) else v
    #             inc(it)
    #         return ret


    # property gamma_sums:
    #     def __get__(self):
    #         ret = []
    #         cdef vector[pBlockMap] gs = self._im.getGammaSums()
    #         cdef vector[pBlockMap].iterator it = gs.begin()
    #         cdef map[block_key, Vector[double]].iterator map_it
    #         cdef pair[block_key, Vector[double]] p
    #         cdef double[::1] vary
    #         cdef int M = len(self.hidden_states) - 1
    #         while it != gs.end():
    #             map_it = deref(it).begin()
    #             pairs = {}
    #             while map_it != deref(it).end():
    #                 p = deref(map_it)
    #                 bk = [0, 0, 0]
    #                 ary = np.zeros(M)
    #                 for i in range(3):
    #                     bk[i] = p.first[i]
    #                 for i in range(M):
    #                     ary[i] = p.second(i)
    #                 pairs[tuple(bk)] = ary
    #                 inc(map_it)
    #             inc(it)
    #             ret.append(pairs)
    #         return ret

    property gammas:
        def __get__(self):
            return _make_em_matrix(self._im.getGammas())

    property xisums:
        def __get__(self):
            return _make_em_matrix(self._im.getXisums())

    property pi:
        def __get__(self):
            return _store_admatrix_helper(self._im.getPi(), self._model.dlist)

    property transition:
        def __get__(self):
            return _store_admatrix_helper(self._im.getTransition(), self._model.dlist)

    property emission:
        def __get__(self):
            return _store_admatrix_helper(self._im.getEmission(), self._model.dlist)

    def Q(self):
        cdef vector[adouble] ad_rets
        with nogil:
            ad_rets = self._im.Q()
        _check_abort()
        cdef int K = ad_rets.size()
        cdef int i
        cdef adouble q
        q = ad_rets[0]
        for i in range(1, K):
            q += ad_rets[i]
        r = adnumber(toDouble(q))
        if self._model.dlist:
            r = _adouble_to_ad(q, self._model.dlist)
        return r

    def loglik(self):
        cdef vector[double] llret
        with nogil:
            llret = self._im.loglik()
        _check_abort()
        return sum(llret)

cdef class PyOnePopInferenceManager(_PyInferenceManager):
    def __cinit__(self, int n, observations, hidden_states):
        # This is needed because cinit cannot be inherited
        self.__my_cinit__(observations, hidden_states)
        with nogil:
            self._im = new OnePopInferenceManager(n, self._Ls, self._obs_ptrs, self._hs)

cdef class PyTwoPopInferenceManager(_PyInferenceManager):
    cdef vector[double*] _emissions_vec
    cdef object _emissions
    cdef TwoPopInferenceManager* _im2

    def __cinit__(self, int n1, int n2, observations, hidden_states):
        # This is needed because cinit cannot be inherited
        self.__my_cinit__(observations, hidden_states)
        with nogil:
            self._im2 = new TwoPopInferenceManager(n1, n2, self._Ls, self._obs_ptrs, self._hs)
            self._im = self._im2
        self.emissions = np.full([len(hidden_states) - 1, 3, n1 + 1, n2 + 1], 1e-20)

    property emissions:
        def __set__(self, emissions):
            self._emissions = emissions
            self._emissions_vec.clear()
            cdef double[:, :, :] emission_view
            for row in self._emissions:
                emission_view = row
                self._emissions_vec.push_back(&emission_view[0, 0, 0])

    property model:
        def __get__(self):
            return self._model

        def __set__(self, model):
            assert len(self._emissions) == len(self._hs) - 1
            self._model = model
            cdef ParameterVector params = make_params(model.distinguished_model)
            with nogil:
                self._im2.setParams(params, self._emissions_vec)

cdef class PyRateFunction:
    cdef unique_ptr[PiecewiseConstantRateFunction[adouble]] _eta
    cdef object _model
    def __cinit__(self, model, hs):
        self._model = model
        cdef ParameterVector params = make_params(model)
        cdef vector[double] _hs = hs
        with nogil:
            self._eta.reset(new PiecewiseConstantRateFunction[adouble](params, _hs))

    def R(self, t):
        assert np.isfinite(t)
        cdef adouble Rt = self._eta.get().R(adouble(t))
        return _adouble_to_ad(Rt, self._model.dlist)

    def random_coal_times(self, t1, t2, K):
        cdef adouble t
        times = []
        for _ in range(K):
            ary = []
            t = self._eta.get().random_time(t1, t2, np.random.randint(six.MAXSIZE))
            ary = [_adouble_to_ad(t, self._model.dlist)]
            t = self._eta.get().R(t)
            ary.append(_adouble_to_ad(t, self._model.dlist))
            times.append(ary)
        return times

def raw_sfs(model, int n, double t1, double t2, below_only=False):
    cdef ParameterVector pv = make_params(model)
    cdef Matrix[adouble] dsfs
    cdef Matrix[double] sfs
    ret = aca(np.zeros([3, n + 1]))
    cdef double[:, ::1] vret = ret
    cdef vector[pair[int, int]] derivs
    cdef bool bo = below_only
    with nogil:
        dsfs = sfs_cython(n, pv, t1, t2, bo)
    _check_abort()
    return _store_admatrix_helper(dsfs, model.dlist)


def thin_data(data, int thinning, int offset=0):
    '''Implement the thinning procedure needed to break up correlation
    among the full SFS emissions.'''
    # Thinning
    cdef int i = offset
    out = []
    cdef int[:, :] vdata = data
    cdef int j
    cdef int k = data.shape[0]
    cdef int span, a, a1
    cdef int npop = data.shape[1] // 2 - 1
    b = np.zeros(npop, dtype=int)
    nb = np.zeros(npop, dtype=int)
    thin = [0, 0] * npop
    for j in range(k):
        span = vdata[j, 0]
        a = vdata[j, 1]
        b[:] = vdata[j, 2::2]
        nb[:] = vdata[j, 3::2]
        a1 = a
        if a1 == 2:
            a1 = 0
        while span > 0:
            if i < thinning and i + span >= thinning:
                if thinning - i > 1:
                    out.append([thinning - i - 1, a1] + thin)
                if a == 2 and np.all(b == nb):
                    fold = sum([[0, nbi] for nbi in nb])
                    out.append([1, 0] + fold)
                else:
                    out.append([1] + list(vdata[j, 1:]))
                span -= thinning - i
                i = 0
            else:
                out.append([span, a1] + thin)
                i += span
                break
    return np.array(out, dtype=np.int32)
