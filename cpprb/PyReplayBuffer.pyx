# distutils: language = c++
# cython: linetrace=True

import ctypes
import multiprocessing
from multiprocessing.sharedctypes import RawArray, RawValue

cimport numpy as np
import numpy as np
import cython
from cython.operator cimport dereference

from cpprb.ReplayBuffer cimport *

from .VectorWrapper cimport *
from .VectorWrapper import (VectorWrapper,
                            VectorInt,VectorSize_t,
                            VectorDouble,PointerDouble,VectorFloat)

cdef double [::1] Cdouble(array):
    return np.ravel(np.array(array,copy=False,dtype=np.double,ndmin=1,order='C'))

cdef size_t [::1] Csize(array):
    return np.ravel(np.array(array,copy=False,dtype=np.uint64,ndmin=1,order='C'))

@cython.embedsignature(True)
cdef inline float [::1] Cfloat(array):
    return np.ravel(np.array(array,copy=False,dtype=np.single,ndmin=1,order='C'))

@cython.embedsignature(True)
cdef class Environment:
    """
    Base class to store environment
    """
    cdef PointerDouble obs
    cdef PointerDouble act
    cdef PointerDouble rew
    cdef PointerDouble next_obs
    cdef PointerDouble done
    cdef size_t buffer_size
    cdef size_t obs_dim
    cdef size_t act_dim
    cdef size_t rew_dim
    cdef bool is_discrete_action
    cdef obs_shape

    def __cinit__(self,size,obs_dim=1,act_dim=1,*,
                  rew_dim=1,is_discrete_action = False,
                  obs_shape = None, **kwargs):
        self.obs_shape = obs_shape
        self.is_discrete_action = is_discrete_action

        cdef size_t _dim
        if self.obs_shape is None:
            self.obs_dim = obs_dim
        else:
            self.obs_dim = 1
            for _dim in self.obs_shape:
                self.obs_dim *= _dim

        self.act_dim = act_dim if not self.is_discrete_action else 1
        self.rew_dim = rew_dim

        self.obs = PointerDouble(ndim=2,value_dim=self.obs_dim,size=size)
        self.act = PointerDouble(ndim=2,value_dim=self.act_dim,size=size)
        self.rew = PointerDouble(ndim=2,value_dim=self.rew_dim,size=size)
        self.next_obs = PointerDouble(ndim=2,value_dim=self.obs_dim,size=size)
        self.done = PointerDouble(ndim=2,value_dim=1,size=size)

    def __init__(self,size,obs_dim=1,act_dim=1,*,
                 rew_dim=1,is_discrete_action = False,
                 obs_shape = None, **kwargs):
        """
        Parameters
        ----------
        size : int
            buffer size
        obs_dim : int, optional
            observation (obs) dimension whose default value is 1
        act_dim : int, optional
            action (act) dimension whose default value is 1
        rew_dim : int, optional
            reward (rew) dimension whose default value is 1
        is_discrete_action: bool, optional
            If True, act_dim is compressed to 1 whose default value is False
        obs_shape: array-like
            observation shape. If not None, overwrite obs_dim.
        """
        pass

    cdef size_t _add(self,double [::1] o,double [::1] a,double [::1] r,
                     double [::1] no,double [::1] d):
        raise NotImplementedError

    def add(self,obs,act,rew,next_obs,done):
        """
        Add environment(s) into replay buffer.
        Multiple step environments can be added.

        Parameters
        ----------
        obs : array_like or float or int
            observation(s)
        act : array_like or float or int
            action(s)
        rew : array_like or float or int
            reward(s)
        next_obs : array_like or float or int
            next observation(s)
        done : array_like or float or int
            done(s)

        Returns
        -------
        int
            the stored first index
        """
        return self._add(Cdouble(obs),Cdouble(act),Cdouble(rew),Cdouble(next_obs),Cdouble(done))

    def _encode_sample(self,idx):
        dtype = np.int if self.is_discrete_action else np.double

        _o = self.obs.as_numpy()[idx]
        _no = self.next_obs.as_numpy()[idx]
        if self.obs_shape is not None:
            _shape = (-1,*self.obs_shape)
            _o = _o.reshape(_shape)
            _no = _no.reshape(_shape)

        return {'obs': _o,
                'act': self.act.as_numpy(dtype=dtype)[idx],
                'rew': self.rew.as_numpy()[idx],
                'next_obs': _no,
                'done': self.done.as_numpy()[idx]}

    cpdef size_t get_buffer_size(self):
        """
        Get buffer size

        Parameters
        ----------

        Returns
        -------
        size_t
            buffer size
        """
        return self.buffer_size

    cdef void _update_size(self,size_t new_size):
        """ Update environment size

        Parameters
        ----------
        new_size : size_t
            new size to set as environment (obs,act,rew,next_obs,done)

        Returns
        -------
        """
        self.obs.update_vec_size(new_size)
        self.act.update_vec_size(new_size)
        self.rew.update_vec_size(new_size)
        self.next_obs.update_vec_size(new_size)
        self.done.update_vec_size(new_size)

    cpdef size_t get_obs_dim(self):
        """Return observation dimension (obs_dim)
        """
        return self.obs_dim

    def get_obs_shape(self):
        """Return observation shape
        """
        return self.obs_shape

    cpdef size_t get_act_dim(self):
        """Return action dimension (act_dim)
        """
        return self.act_dim

    cpdef size_t get_rew_dim(self):
        """Return reward dimension (rew_dim)
        """
        return self.rew_dim


@cython.embedsignature(True)
cdef class SelectiveEnvironment(Environment):
    """
    Base class for episode level management envirionment
    """
    cdef CppSelectiveEnvironment[double,double,double,double] *buffer
    def __cinit__(self,episode_len,obs_dim=1,act_dim=1,*,Nepisodes=10,rew_dim=1,**kwargs):
        self.buffer_size = episode_len * Nepisodes

        self.buffer = new CppSelectiveEnvironment[double,double,
                                                  double,double](episode_len,
                                                                 Nepisodes,
                                                                 self.obs_dim,
                                                                 self.act_dim,
                                                                 self.rew_dim)

        self.buffer.get_buffer_pointers(self.obs.ptr,
                                        self.act.ptr,
                                        self.rew.ptr,
                                        self.next_obs.ptr,
                                        self.done.ptr)

    def __init__(self,episode_len,obs_dim=1,act_dim=1,*,Nepisodes=10,rew_dim=1,**kwargs):
        """
        Parameters
        ----------
        episode_len : int
            the mex size of environments in a single episode
        obs_dim : int
            observation (obs, next_obs) dimension
        act_dim : int
            action (act) dimension
        Nepisodes : int, optional
            the max size of stored episodes
        rew_dim : int, optional
            reward (rew) dimension
        """
        pass

    cdef size_t _add(self,double [::1] obs,double [::1] act, double [::1] rew,
                     double [::1] next_obs, double [::1] done):
        return self.buffer.store(&obs[0],&act[0],&rew[0],
                                 &next_obs[0],&done[0],done.shape[0])

    cpdef void clear(self) except *:
        """
        Clear replay buffer.

        Parameters
        ----------

        Returns
        -------
        """
        clear(self.buffer)

    cpdef size_t get_stored_size(self):
        """
        Get stored size

        Parameters
        ----------

        Returns
        -------
        size_t
            stored size
        """
        return get_stored_size(self.buffer)

    cpdef size_t get_next_index(self):
        """
        Get the next index to store

        Parameters
        ----------

        Returns
        -------
        size_t
            the next index to store
        """
        return get_next_index(self.buffer)

    cpdef size_t get_stored_episode_size(self):
        """
        Get the size of stored episodes

        Parameters
        ----------

        Returns
        -------
        size_t
            the size of stored episodes
        """
        return self.buffer.get_stored_episode_size()

    cpdef size_t delete_episode(self,i):
        """
        Delete specified episode

        The stored environment after specified episode are moved to backward.

        Parameters
        ----------
        i : int
            the index of delete episode

        Returns
        -------
        size_t
            the size of environments in the deleted episodes
        """
        return self.buffer.delete_episode(i)

    def get_episode(self,i):
        """
        Get specified episode

        Parameters
        ----------
        i : int
            the index of extracted episode

        Returns
        -------
        dict of ndarray
            the set environment in i-th episode
        """
        cdef size_t len = 0
        self.buffer.get_episode(i,len,
                                self.obs.ptr,self.act.ptr,self.rew.ptr,
                                self.next_obs.ptr,self.done.ptr)
        if len == 0:
            return {'obs': np.ndarray((0,self.obs_dim)),
                    'act': np.ndarray((0,self.act_dim)),
                    'rew': np.ndarray((0,self.rew_dim)),
                    'next_obs': np.ndarray((0,self.obs_dim)),
                    'done': np.ndarray(0)}

        self._update_size(len)
        return {'obs': self.obs.as_numpy(),
                'act': self.act.as_numpy(),
                'rew': self.rew.as_numpy(),
                'next_obs': self.next_obs.as_numpy(),
                'done': self.done.as_numpy()}

    def _encode_sample(self,indexes):
        self.buffer.get_buffer_pointers(self.obs.ptr,
                                        self.act.ptr,
                                        self.rew.ptr,
                                        self.next_obs.ptr,
                                        self.done.ptr)
        cdef size_t buffer_size = self.get_buffer_size()
        self._update_size(buffer_size)
        return super()._encode_sample(indexes)

@cython.embedsignature(True)
cdef class SelectiveReplayBuffer(SelectiveEnvironment):
    """
    Replay buffer to store episodes of environment.

    This class can get and delete a episode.
    """
    def __cinit__(self,episode_len,obs_dim=1,act_dim=1,*,Nepisodes=10,rew_dim=1,**kwargs):
        pass

    def __init__(self,episode_len,obs_dim=1,act_dim=1,*,Nepisodes=10,rew_dim=1,**kwargs):
        """
        Parameters
        ----------
        episode_len : int
            the max size of a single episode
        obs_dim : int
            observation (obs, next_obs) dimension
        act_dim : int
            action (act) dimension
        Nepisodes : int, optional
            the max size of stored episodes whose default value is 10
        rew_dim : int, optional
            reward (rew) dimension whose dimension is 1
        """
        pass

    def sample(self,batch_size):
        """
        Sample the stored environment randomly with speciped size

        Parameters
        ----------
        batch_size : int
            sampled batch size

        Returns
        -------
        sample : dict of ndarray
            batch size of samples, which might contains the same event multiple times.
        """
        cdef idx = np.random.randint(0,self.get_stored_size(),batch_size)
        return self._encode_sample(idx)

def shared_ndarray(shape,dtype):
    shape = np.asarray(shape)
    _ctype = np.ctypeslib.as_ctypes_type(dtype)

    memory = RawArray(_ctype,shape.prod())
    return np.lib.stride_tricks.as_strided(np.ctypeslib.as_array(memory),
                                           shape=shape)

def dict2buffer(buffer_size,env_dict,*,
                stack_compress = None,default_dtype = None, enable_shared = False):
    """Create buffer from env_dict

    Parameters
    ----------
    buffer_size : int
        buffer size
    env_dict : dict of dict
        Specify environment values to be stored in buffer.
    stack_compress : str or array like of str, optional
        compress memory of specified stacked values.
    default_dtype : numpy.dtype, optional
        fallback dtype for not specified in `env_dict`. default is numpy.single
    enable_shared : bool, optional
        use shared memory for `multiprocessing`. default is `Fault`

    Returns
    -------
    buffer : dict of numpy.ndarray
        buffer for environment specified by env_dict.
    """
    cdef buffer = {}
    cdef bool compress_any = stack_compress
    default_dtype = default_dtype or np.single

    if enable_shared:
        create_array = shared_ndarray
    else:
        create_array = np.zeros

    for name, defs in env_dict.items():
        shape = np.insert(np.asarray(defs.get("shape",1)),0,buffer_size)

        if compress_any and np.isin(name,
                                    stack_compress,
                                    assume_unique=True).any():
            buffer_shape = np.insert(np.delete(shape,-1),1,shape[-1])
            buffer_shape[0] += buffer_shape[1] - 1
            buffer_shape[1] = 1
            memory = create_array(buffer_shape,
                                  dtype=defs.get("dtype",default_dtype))
            strides = np.append(np.delete(memory.strides,1),memory.strides[1])
            buffer[name] = np.lib.stride_tricks.as_strided(memory,
                                                           shape=shape,
                                                           strides=strides)
        else:
            buffer[name] = create_array(shape,dtype=defs.get("dtype",default_dtype))

        shape[0] = -1
        defs["add_shape"] = shape
    return buffer

def find_array(dict,key):
    """Find 'key' and ensure numpy.ndarray with the minimum dimension of 1.

    Parameters
    ----------
    dict : dict
        dict where find 'key'
    key : str
        dictionary key to find

    Returns
    -------
    : numpy.ndarray or None
        If `dict` has `key`, returns the values with numpy.ndarray with the minimum
        dimension of 1. Otherwise, returns `None`.
    """
    return None if not key in dict else np.array(dict[key],ndmin=1,copy=False)

@cython.embedsignature(True)
cdef class StepChecker:
    """Check the step size of addition
    """
    cdef check_str
    cdef check_shape

    def __cinit__(self,env_dict):
        for name, defs in env_dict.items():
            self.check_str = name
            self.check_shape = defs["add_shape"]

    def __init__(self,env_dict):
        """Initialize StepChecker class.

        Parameters
        ----------
        env_dict : dict
            Specify the environment values.
        """
        pass

    cdef size_t step_size(self,kwargs) except *:
        """Return step size.

        Parameters
        ----------
        kwargs: dict
            Added values.
        """
        return np.reshape(kwargs[self.check_str],self.check_shape,order='A').shape[0]

@cython.embedsignature(True)
cdef class NstepBuffer:
    """Local buffer class for Nstep reward.

    This buffer temporary stores environment values and returns Nstep-modified
    environment values for `ReplayBuffer`
    """
    cdef buffer
    cdef size_t buffer_size
    cdef default_dtype
    cdef size_t stored_size
    cdef size_t Nstep_size
    cdef float Nstep_gamma
    cdef Nstep_rew
    cdef Nstep_next
    cdef env_dict
    cdef stack_compress
    cdef StepChecker size_check

    def __cinit__(self,env_dict=None,Nstep=None,*,
                  stack_compress = None,default_dtype = None,next_of = None):
        self.env_dict = env_dict.copy() if env_dict else {}
        self.stored_size = 0
        self.stack_compress = None # stack_compress is not support yet.
        self.default_dtype = default_dtype or np.single

        if next_of is not None: # next_of is not support yet.
            for name in np.array(next_of,copy=False,ndmin=1):
                self.env_dict[f"next_{name}"] = self.env_dict[name]
            del self.env_dict["next_of"]

        self.Nstep_size = Nstep["size"]
        self.Nstep_gamma = Nstep.get("gamma",0.99)
        self.Nstep_rew = find_array(Nstep,"rew")
        self.Nstep_next = find_array(Nstep,"next")

        self.buffer_size = self.Nstep_size - 1
        self.buffer = dict2buffer(self.buffer_size,self.env_dict,
                                  stack_compress = self.stack_compress,
                                  default_dtype = self.default_dtype)
        self.size_check = StepChecker(self.env_dict)

    def __init__(self,env_dict=None,Nstep=None,*,
                 stack_compress = None,default_dtype = None, next_of = None):
        """Initialize NstepBuffer class.

        Parameters
        ----------
        env_dict : dict
            Specify environment values to be stored.
        Nstep : dict
            `Nstep["size"]` is `int` specifying step size of Nstep reward.
            `Nstep["rew"]` is `str` or array like of `str` specifying
            Nstep reward to be summed. `Nstep["gamma"]` is float specifying
            discount factor, its default is 0.99. `Nstep["next"]` is `str` or
            list of `str` specifying next values to be moved.
        stack_compress : str or array like of str, optional
            compress memory of specified stacked values.
        default_dtype : numpy.dtype, optional
            fallback dtype for not specified in `env_dict`. default is numpy.single
        next_of : str or array like of str, optional
            next item of specified environemt variables (eg. next_obs for next) are
            also sampled without duplicated values

        Notes
        -----
        Currently, memory compression features (`stack_compress` and `next_of`) are
        not supported yet. (Fall back to usual storing)
        """
        pass

    def add(self,*,**kwargs):
        """Add envronment into local buffer.

        Paremeters
        ----------
        **kwargs : keyword arguments
            Values to be added.

        Returns
        -------
        env : dict or None
            Values with Nstep reward calculated. When the local buffer does not
            store enough cache items, returns 'None'.
        """
        cdef size_t N = self.size_check.step_size(kwargs)
        cdef ssize_t end = self.stored_size + N

        cdef ssize_t i
        cdef ssize_t stored_begin
        cdef ssize_t stored_end
        cdef ssize_t ext_begin
        cdef ssize_t max_slide

        if end <= self.buffer_size:
            for name, stored_b in self.buffer.items():
                if self.Nstep_rew is not None and np.isin(name,self.Nstep_rew).any():
                    # Calculate later.
                    pass
                elif (self.Nstep_next is not None
                      and np.isin(name,self.Nstep_next).any()):
                    # Do nothing.
                    pass
                else:
                    stored_b[self.stored_size:end] = self._extract(kwargs,name)

            # Nstep reward must be calculated after "done" filling
            gamma = (1.0 - self.buffer["done"][:end]) * self.Nstep_gamma

            if self.Nstep_rew is not None:
                max_slide = min(self.Nstep_size - self.stored_size,N)
                max_slide *= -1
                for name in self.Nstep_rew:
                    ext_b = self._extract(kwargs,name).copy()
                    self.buffer[name][self.stored_size:end] = ext_b

                    for i in range(self.stored_size-1,max_slide,-1):
                        stored_begin = max(i,0)
                        stored_end = i+N
                        ext_begin = max(-i,0)
                        ext_b[ext_begin:] *= gamma[stored_begin:stored_end]
                        self.buffer[name][stored_begin:stored_end] +=ext_b[ext_begin:]

            self.stored_size = end
            return None

        cdef size_t diff_N = self.buffer_size - self.stored_size
        cdef size_t add_N = N - diff_N
        cdef bool NisBigger = (add_N > self.buffer_size)
        end = self.buffer_size if NisBigger else add_N

        # Nstep reward must be calculated before "done" filling
        cdef ssize_t spilled_N
        gamma = np.ones((self.stored_size + N,1),dtype=np.single)
        gamma[:self.stored_size] -= self.buffer["done"][:self.stored_size]
        gamma[self.stored_size:] -= self._extract(kwargs,"done")
        gamma *= self.Nstep_gamma
        if self.Nstep_rew is not None:
            max_slide = min(self.Nstep_size - self.stored_size,N)
            max_slide *= -1
            for name in self.Nstep_rew:
                stored_b = self.buffer[name]
                ext_b = self._extract(kwargs,name)

                copy_ext = ext_b.copy()
                if diff_N:
                    stored_b[self.stored_size:] = ext_b[:diff_N]
                    ext_b = ext_b[diff_N:]

                for i in range(self.stored_size-1,max_slide,-1):
                    stored_begin = max(i,0)
                    stored_end = i+N
                    ext_begin = max(-i,0)
                    copy_ext[ext_begin:] *= gamma[stored_begin:stored_end]
                    if stored_end <= self.buffer_size:
                        stored_b[stored_begin:stored_end] += copy_ext[ext_begin:]
                    else:
                        spilled_N = stored_end - self.buffer_size
                        stored_b[stored_begin:] += copy_ext[ext_begin:-spilled_N]
                        ext_b[:spilled_N] += copy_ext[-spilled_N:]

                self._roll(stored_b,ext_b,end,NisBigger,kwargs,name,add_N)

        for name, stored_b in self.buffer.items():
            if self.Nstep_rew is not None and np.isin(name,self.Nstep_rew).any():
                # Calculated.
                pass
            elif (self.Nstep_next is not None
                  and np.isin(name,self.Nstep_next).any()):
                kwargs[name] = self._extract(kwargs,name)[diff_N:]
            else:
                ext_b = self._extract(kwargs,name)

                if diff_N:
                    stored_b[self.stored_size:] = ext_b[:diff_N]
                    ext_b = ext_b[diff_N:]

                self._roll(stored_b,ext_b,end,NisBigger,kwargs,name,add_N)

        done = kwargs["done"]
        kwargs["discounts"] = np.where(done,1,self.Nstep_gamma)

        for i in range(1,self.buffer_size):
            if i <= add_N:
                done[:-i] += kwargs["done"][i:]
                done[-i:] += self.buffer["done"][:i]
            else:
                done += self.buffer["done"][i-add_N:i]

            kwargs["discounts"][done == 0] *= self.Nstep_gamma


        self.stored_size = self.buffer_size
        return kwargs

    cdef _extract(self,kwargs,name):
        _dict = self.env_dict[name]
        return np.reshape(np.array(kwargs[name],copy=False,ndmin=2,
                                   dtype=_dict.get("dtype",self.default_dtype)),
                          _dict["add_shape"])

    cdef void _roll(self,stored_b,ext_b,
                    ssize_t end,bool NisBigger,kwargs,name,size_t add_N):
        # Swap numpy.ndarray
        # https://stackoverflow.com/a/33362030
        stored_b[:end], ext_b[-end:] = ext_b[-end:], stored_b[:end].copy()
        if NisBigger:
            # buffer: XXXX, add: YYYYY
            # buffer: YYYY, add: YXXXX
            ext_b = np.roll(ext_b,end,axis=0)
            # buffer: YYYY, add: XXXXY
        else:
            # buffer: XXXZZZZ, add: YYY
            # buffer: YYYZZZZ, add: XXX
            stored_b[:] = np.roll(stored_b,-end,axis=0)[:]
            # buffer: ZZZZYYY, add: XXX
        kwargs[name] = ext_b[:add_N]

    cpdef void clear(self):
        """Clear the bufer.
        """
        self.stored_size = 0

    cpdef on_episode_end(self):
        """Terminate episode.
        """
        kwargs = self.buffer.copy()
        done = kwargs["done"]
        kwargs["discounts"] = np.where(done,1,self.Nstep_gamma)

        for i in range(1,self.buffer_size):
            done[:-i] += kwargs["done"][i:]
            kwargs["discounts"][done == 0] *= self.Nstep_gamma

        self.clear()
        return kwargs

    cpdef size_t get_Nstep_size(self):
        """Get Nstep size

        Returns
        -------
        Nstep_size : size_t
            Nstep size
        """
        return self.Nstep_size

@cython.embedsignature(True)
cdef class ReplayBuffer:
    """Replay Buffer class to store environments and to sample them randomly.

    The envitonment contains observation (obs), action (act), reward (rew),
    the next observation (next_obs), and done (done).

    In this class, sampling is random sampling and the same environment can be
    chosen multiple times.
    """
    cdef buffer
    cdef size_t buffer_size
    cdef env_dict
    cdef size_t index
    cdef size_t stored_size
    cdef next_of
    cdef bool has_next_of
    cdef next_
    cdef bool compress_any
    cdef stack_compress
    cdef cache
    cdef default_dtype
    cdef StepChecker size_check
    cdef NstepBuffer nstep
    cdef bool use_nstep
    cdef bool enable_shared

    def __cinit__(self,size,env_dict=None,*,
                  next_of=None,stack_compress=None,default_dtype=None,Nstep=None,
                  enable_shared = False,
                  **kwargs):
        self.env_dict = env_dict or {}
        self.buffer_size = size
        self.stored_size = 0
        self.index = 0
        self.enable_shared = enable_shared

        self.compress_any = stack_compress
        self.stack_compress = np.array(stack_compress,ndmin=1,copy=False)

        self.default_dtype = default_dtype or np.single

        self.use_nstep = Nstep
        if self.use_nstep:
            self.nstep = NstepBuffer(self.env_dict,Nstep,
                                     stack_compress = self.stack_compress,
                                     next_of = self.next_of,
                                     default_dtype = self.default_dtype)
            self.env_dict["discounts"] = {"dtype": np.single}

        self.buffer = dict2buffer(self.buffer_size,self.env_dict,
                                  stack_compress = self.stack_compress,
                                  default_dtype = self.default_dtype)

        self.size_check = StepChecker(self.env_dict)

        self.next_of = np.array(next_of,ndmin=1,copy=False)
        self.has_next_of = next_of
        self.next_ = {}
        self.cache = {} if (self.has_next_of or self.compress_any) else None

        if self.has_next_of:
            for name in self.next_of:
                self.next_[name] = self.buffer[name][0].copy()

    def __init__(self,size,env_dict=None,*,
                 next_of=None,stack_compress=None,default_dtype=None,Nstep=None,
                 **kwargs):
        """Initialize ReplayBuffer

        Parameters
        ----------
        size : int
            buffer size
        env_dict : dict of dict, optional
            dictionary specifying environments. The keies of env_dict become
            environment names. The values of env_dict, which are also dict,
            defines "shape" (default 1) and "dtypes" (fallback to `default_dtype`)
        next_of : str or array like of str, optional
            next item of specified environemt variables (eg. next_obs for next) are
            also sampled without duplicated values
        stack_compress : str or array like of str, optional
            compress memory of specified stacked values.
        default_dtype : numpy.dtype, optional
            fallback dtype for not specified in `env_dict`. default is numpy.single
        Nstep : dict, optional
            `Nstep["size"]` is `int` specifying step size of Nstep reward.
            `Nstep["rew"]` is `str` or array like of `str` specifying
            Nstep reward to be summed. `Nstep["gamma"]` is float specifying
            discount factor, its default is 0.99. `Nstep["next"]` is `str` or
            list of `str` specifying next values to be moved.
        """
        pass

    def add(self,*,**kwargs):
        """Add environment(s) into replay buffer.
        Multiple step environments can be added.

        Parameters
        ----------
        **kwargs : array like or float or int
            environments to be stored

        Returns
        -------
        : int or None
            the stored first index. If all values store into NstepBuffer and
            no values store into main buffer, return None.

        Raises
        ------
        KeyError
            When kwargs don't include all environment variables defined in __cinit__
            When environment variables don't include "done"
        """
        if self.use_nstep:
            kwargs = self.nstep.add(**kwargs)
            if kwargs is None:
                return

        cdef size_t N = self.size_check.step_size(kwargs)

        cdef size_t index = self.index
        cdef size_t end = index + N
        cdef size_t remain = 0
        cdef add_idx = np.arange(index,end)

        if end > self.buffer_size:
            remain = end - self.buffer_size
            add_idx[add_idx >= self.buffer_size] -= self.buffer_size

        for name, b in self.buffer.items():
            b[add_idx] = np.reshape(np.array(kwargs[name],copy=False,ndmin=2),
                                    self.env_dict[name]["add_shape"])

        if self.has_next_of:
            for name in self.next_of:
                self.next_[name][...]=np.reshape(np.array(kwargs[f"next_{name}"],
                                                          copy=False,
                                                          ndmin=2),
                                                 self.env_dict[name]["add_shape"])[-1]

        if (self.cache is not None) and (index in self.cache):
            del self.cache[index]

        self.stored_size = min(self.stored_size + N,self.buffer_size)
        self.index = end if end < self.buffer_size else remain
        return index

    def _encode_sample(self,idx):
        cdef sample = {}
        cdef next_idx
        cdef cache_idx
        cdef bool use_cache

        idx = np.array(idx,copy=False,ndmin=1)
        for name, b in self.buffer.items():
            sample[name] = b[idx]

        if self.has_next_of:
            next_idx = idx + 1
            next_idx[next_idx == self.get_buffer_size()] = 0
            cache_idx = (next_idx == self.get_next_index())
            use_cache = cache_idx.any()

            for name in self.next_of:
                sample[f"next_{name}"] = self.buffer[name][next_idx]
                if use_cache:
                    sample[f"next_{name}"][cache_idx] = self.next_[name]

        cdef size_t i
        if self.cache is not None:
            for i in idx:
                if i in self.cache:
                    if self.has_next_of:
                        for name in self.next_of:
                            sample[f"next_{name}"][i] = self.cache[i][f"next_{name}"]
                    if self.compress_any:
                        for name in self.stack_compress:
                            sample[name][i] = self.cache[i][name]

        return sample

    def sample(self,batch_size):
        """Sample the stored environment randomly with speciped size

        Parameters
        ----------
        batch_size : int
            sampled batch size

        Returns
        -------
        sample : dict of ndarray
            batch size of samples, which might contains the same event multiple times.
        """
        cdef idx = np.random.randint(0,self.get_stored_size(),batch_size)
        return self._encode_sample(idx)

    cpdef void clear(self) except *:
        """Clear replay buffer.

        Set `index` and `stored_size` to 0.

        Example
        -------
        >>> rb = ReplayBuffer(5,{"done",{}})
        >>> rb.add(1)
        >>> rb.get_stored_size()
        1
        >>> rb.get_next_index()
        1
        >>> rb.clear()
        >>> rb.get_stored_size()
        0
        >>> rb.get_next_index()
        0
        """
        self.index = 0
        self.stored_size = 0

        if self.use_nstep:
            self.nstep.clear()

    cpdef size_t get_stored_size(self):
        """Get stored size

        Returns
        -------
        size_t
            stored size
        """
        return self.stored_size

    cpdef size_t get_buffer_size(self):
        """Get buffer size

        Returns
        -------
        size_t
            buffer size
        """
        return self.buffer_size

    cpdef size_t get_next_index(self):
        """Get the next index to store

        Returns
        -------
        size_t
            the next index to store
        """
        return self.index

    cdef void add_cache(self):
        """Add last items into cache
        """
        cdef size_t key = (self.index or self.buffer_size) -1
        self.cache[key] = {}

        if self.has_next_of:
            for name, value in self.next_.items():
                self.cache[key][f"next_{name}"] = value

        if self.compress_any:
            for name in self.stack_compress:
                self.cache[key][name] = self.buffer[name][key].copy()

    cpdef void on_episode_end(self):
        """Call on episode end

        Notes
        -----
        This is necessary for stack compression (stack_compress) mode or next
        compression (next_of) mode.
        """
        if self.use_nstep:
            self.use_nstep = False
            self.add(**self.nstep.on_episode_end())
            self.use_nstep = True

        if self.cache is not None:
            self.add_cache()

    def explore(self,env_factory,policy,post_step_func,*,
                pre_add_func=None, max_episode_step=None, n_env=64, n_parallel=1,
                env_dict = None):
        """
        Run exploration

        Parameters
        ----------
        env_factory : function-like
            Factory function (or functor) creating an environment. Multiple call
            must return different instances if the environment has internal state.
        plicy : functor
            Actor functor to get action(s) from observation(s). The actor must have
            a member function `update(*args)`
        post_step_func : functor
            Function taking returns of `gym.Env.step` (aka. `tuple`) and returning
            `dict` for `ReplayBuffer.add`
        pre_add_func : functor, optional
            Function taking `policy` and environment variables and returning `dict`
            for `ReplayBuffer.add`. This functor is intended to calculate TD error.
            If no functor is specified, the environmental variables are added to
            the replay buffer without modification.
        max_episode_step : int (optional)
            Maximum step size in a single episode. If the value is `None` (default),
            the episode will not terminate until `done=1`.
        n_env : int (optional)
            Number of environments, whose default is 64.
        n_parallel : int (optional)
            Number of parallel exploration, whose default is 1.
        env_dict : dict, optional
            Environment definition `dict`. If no dict is specified (default),
            `self.env_dict` is used.

        Returns
        -------

        """
        if not self.enable_shared:
            return False

        env_dict = env_dict or self.env_dict
        shared_buffer = dict2buffer(n_env,env_dict,
                                    default_dtype = self.default_dtype,
                                    enable_shared = True)

        waiting_policy = dict2buffer(n_parallel,{"_": {"dtype": ctypes.c_bool}},
                                     enable_shared = True)["_"]

        self.start_adding_process(policy=policy,
                                  shared_buffer=shared_buffer,
                                  not_ready = not_ready,
                                  pre_add_func=pre_add_func,
                                  n_env=n_env)

        self.start_stepping_process(env_factory=env_factory,
                                    shared_buffer=shared_buffer,
                                    waiting_policy = waiting_policy,
                                    post_step_func=post_step_func,
                                    n_env=n_env,
                                    n_parallel=n_parallel)

def _stepping_func(env_factory,shared_buffer,waiting_policy,post_step_func,n_env,*,
                   obs_name = 'obs',
                   act_name = 'act',
                   max_episode_step = None):
    cdef list envs = []
    cdef size_t i = 0
    cdef size_t n = n_env
    cdef obs = shared_buffer[obs_name]
    cdef act = shared_buffer[act_name]

    for i in range(n):
        envs.append(env_factory())

    for i in range(n):
        obs[i] = envs[i].reset()

    waiting_policy = True

    while True:
        if waiting_policy:
            continue

        for i in range(n):
            for k,v in post_step_func(envs[i].step(act[i])).items():
                shared_buffer[k][i] = v

        waiting_policy = True

def _adding_func(buffer, policy, shared_buffer, waiting_policy,*,
                 obs_name = 'obs',
                 next_obs_name = 'next_obs',
                 act_name = 'act',
                 pre_add_func = None):

    cdef obs = shared_buffer[obs_name]
    cdef act = shared_buffer[act_name]
    cdef next_obs = shared_buffer[next_obs_name]
    cdef size_t total_step = 0

    if pre_add_func is None:
        pre_add_func = lambda p,b: b

    while True:
        if not waiting_policy.all():
            continue
        total_step += 1

        kwargs = pre_add_func(policy,shared_buffer)

        buffer.add(**kwargs)
        act = policy(obs)
        obs[:] = next_obs[:]

        waiting_policy[:] = False

@cython.embedsignature(True)
cdef class PrioritizedReplayBuffer(ReplayBuffer):
    """Prioritized replay buffer class to store environments with priorities.

    In this class, these environments are sampled with corresponding priorities.
    """
    cdef VectorFloat weights
    cdef VectorSize_t indexes
    cdef float alpha
    cdef CppPrioritizedSampler[float]* per
    cdef NstepBuffer priorities_nstep
    cdef bool check_for_update
    cdef bool [:] unchange_since_sample

    def __cinit__(self,size,env_dict=None,*,alpha=0.6,Nstep=None,eps=1e-4,
                  check_for_update=False,**kwrags):
        self.alpha = alpha
        self.per = new CppPrioritizedSampler[float](size,alpha)
        self.per.set_eps(eps)
        self.weights = VectorFloat()
        self.indexes = VectorSize_t()

        if self.use_nstep:
            self.priorities_nstep = NstepBuffer({"priorities": {"dtype": np.single},
                                                 "done": {}},
                                                {"size": Nstep["size"]})

        self.check_for_update = check_for_update
        if self.check_for_update:
            self.unchange_since_sample = np.ones(np.array(size,
                                                          copy=False,
                                                          dtype='int'),
                                                 dtype='bool')

    def __init__(self,size,env_dict=None,*,alpha=0.6,Nstep=None,eps=1e-4,
                 check_for_update=False,**kwargs):
        """Initialize PrioritizedReplayBuffer

        Parameters
        ----------
        size : int
            buffer size
        env_dict : dict of dict, optional
            dictionary specifying environments. The keies of env_dict become
            environment names. The values of env_dict, which are also dict,
            defines "shape" (default 1) and "dtypes" (fallback to `default_dtype`)
        alpha : float, optional
            the exponent of the priorities in stored whose default value is 0.6
        eps : float, optional
            small positive constant to ensure error-less state will be sampled,
            whose default value is 1e-4.
        check_for_update : bool
            Whether check update for `update_priorities`. The default value is `False`
        """
        pass

    def add(self,*,priorities = None,**kwargs):
        """Add environment(s) into replay buffer.

        Multiple step environments can be added.

        Parameters
        ----------
        priorities : array like or float or int
            priorities of each environment
        **kwargs : array like or float or int optional
            environment(s) to be stored

        Returns
        -------
        : int or None
            the stored first index. If all values store into NstepBuffer and
            no values store into main buffer, return None.
        """
        cdef size_t N = np.ravel(kwargs.get("done")).shape[0]

        if self.use_nstep:
            if priorities is None:
                priorities = np.full((N),self.get_max_priority(),dtype=np.single)

            priorities = self.priorities_nstep.add(priorities=priorities,
                                                   done=np.array(kwargs["done"],
                                                                 copy=True))
            if priorities is not None:
                priorities = priorities["priorities"]

        cdef maybe_index = super().add(**kwargs)
        if maybe_index is None:
            return None

        N = np.ravel(kwargs.get("done")).shape[0]
        cdef size_t index = maybe_index
        cdef float [:] ps

        if priorities is not None:
            ps = np.ravel(np.array(priorities,copy=False,ndmin=1,dtype=np.single))
            self.per.set_priorities(index,&ps[0],N,self.get_buffer_size())
        else:
            self.per.set_priorities(index,N,self.get_buffer_size())

        if self.check_for_update:
            if index+N <= self.buffer_size:
                self.unchange_since_sample[index:index+N] = False
            else:
                self.unchange_since_sample[index:] = False
                self.unchange_since_sample[:index+N-self.buffer_size] = False

        return index

    def sample(self,batch_size,beta = 0.4):
        """Sample the stored environment depending on correspoinding priorities
        with speciped size

        Parameters
        ----------
        batch_size : int
            sampled batch size
        beta : float, optional
            the exponent for discount priority effect whose default value is 0.4

        Returns
        -------
        sample : dict of ndarray
            batch size of samples which also includes 'weights' and 'indexes'


        Notes
        -----
        When 'beta' is 0, priorities are ignored.
        The greater 'beta', the bigger effect of priories.

        The sampling probabilities are propotional to :math:`priorities ^ {-'beta'}`
        """
        self.per.sample(batch_size,beta,
                        self.weights.vec,self.indexes.vec,
                        self.get_stored_size())
        cdef idx = self.indexes.as_numpy()
        samples = self._encode_sample(idx)
        samples['weights'] = self.weights.as_numpy()
        samples['indexes'] = idx

        if self.check_for_update:
            self.unchange_since_sample[:] = True

        return samples

    def update_priorities(self,indexes,priorities):
        """Update priorities

        Parameters
        ----------
        indexes : array_like
            indexes to update priorities
        priorities : array_like
            priorities to update

        Returns
        -------
        """
        cdef size_t [:] idx = Csize(indexes)
        cdef float [:] ps = Cfloat(priorities)

        cdef size_t _idx = 0
        if self.check_for_update:
            for _i in range(idx.shape[0]):
                if self.unchange_since_sample[idx[_i]]:
                    idx[_idx] = idx[_i]
                    ps[_idx] = ps[_i]
                    _idx += 1
            idx = idx[:_idx]
            ps = ps[:_idx]


        cdef N = idx.shape[0]
        if N > 0:
            self.per.update_priorities(&idx[0],&ps[0],N)

    cpdef void clear(self) except *:
        """Clear replay buffer
        """
        super(PrioritizedReplayBuffer,self).clear()
        clear(self.per)
        if self.use_nstep:
            self.priorities_nstep.clear()

    cpdef float get_max_priority(self):
        """Get the max priority of stored priorities

        Returns
        -------
        max_priority : float
            the max priority of stored priorities
        """
        return self.per.get_max_priority()

    cpdef void on_episode_end(self):
        """Call on episode end

        Notes
        -----
        This is necessary for stack compression (stack_compress) mode or next
        compression (next_of) mode.
        """
        if self.use_nstep:
            self.use_nstep = False
            self.add(**self.nstep.on_episode_end(),
                     **self.priorities_nstep.on_episode_end())
            self.use_nstep = True

        if self.cache is not None:
            self.add_cache()

def create_buffer(size,env_dict=None,*,prioritized = False,**kwargs):
    """Create specified version of replay buffer

    Parameters
    ----------
    size : int
        buffer size
    env_dict : dict of dict, optional
        dictionary specifying environments. The keies of env_dict become
        environment names. The values of env_dict, which are also dict,
        defines "shape" (default 1) and "dtypes" (fallback to `default_dtype`)
    prioritized : bool, optional
        create prioritized version replay buffer, default = False

    Returns
    -------
    : one of the replay buffer classes

    Raises
    ------
    NotImplementedError
        If you specified not implemented version replay buffer

    Note
    ----
    Any other keyword arguments are passed to replay buffer constructor.
    """
    per = "Prioritized" if prioritized else ""

    buffer_name = f"{per}ReplayBuffer"

    cls={"ReplayBuffer": ReplayBuffer,
         "PrioritizedReplayBuffer": PrioritizedReplayBuffer}

    buffer = cls.get(f"{buffer_name}",None)

    if buffer:
        return buffer(size,env_dict,**kwargs)

    raise NotImplementedError(f"{buffer_name} is not Implemented")
