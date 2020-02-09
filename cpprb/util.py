import numpy as np

from gym.spaces import Spaces, Box, Discrete, MultiDiscrete, MultiBinary, Tuple, Dict
from gym.spaces import flatdim, flatten, unflatten

def from_space(space,int_type,float_type):
    if isinstance(space,Discrete):
        return {"dtype": int_type,"shape": 1}
    elif isinstance(space,MultiDiscrete):
        return {"dtype": int_type,"shape": space.nvec.shape}
    elif isinstance(space,Box):
        return {"dtype": float_type,"shape": space.shape}
    elif isinstance(space,MultiBinary):
        return {"dtype": int_type, "shape": space.n}
    else:
        raise NotImplementedError(f"Error: Unknown Space {space}")

def create_env_dict(env,*,int_type = None,float_type = None):
    """
    Create `env_dict` from Open AI `gym.space` for `ReplayBuffer.__init__`

    Paremeters
    ----------
    env : gym.space
        Environment
    int_type: np.dtype, optional
        Integer type. Default is `np.int32`
    float_type: np.dtype, optional
        Floating point type. Default is `np.float32`

    Returns
    -------
    env_dict : dict
        env_dict parameter for `ReplayBuffer` class.
    """

    int_type = int_type or np.int32
    float_type = float_type or np.float32

    env_dict = {"rew" : {"shape": 1, "dtype": float_type},
                "done": {"shape": 1, "dtype": float_type}}

    observation_space = env.observation_space
    action_space = env.action_space

    env_dict["obs"] = from_space(observation_space,int_type,float_type)
    env_dict["next_obs"] = from_space(observation_space,int_type,float_type)
    env_dict["act"] = from_space(action_space,int_type,float_type)

    return env_dict
