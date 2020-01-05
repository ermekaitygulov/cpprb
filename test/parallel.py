import random
import unittest
import multiprocessing

import numpy as np
from cpprb import ReplayBuffer, PrioritizedReplayBuffer

@unittest.skipIf(multiprocessing.cpu_count() < 2)
class TestPerallelExplore(unittest.TestCase):
    def test_explore(self):

        env_func = lambda : gym.make("FrozenLake-v0")
        policy = lambda o: random.randint(1,4)
        post = lambda args: {"next_obs": args[0],
                             "rew": args[1],
                             "done": args[2]}
        buffer_size = 256

        rb = ReplayBuffer(buffer_size,
                          {"obs": {"dtype": np.int},
                           "act": {"dtype": np.int},
                           "next_obs": {"dtype": np.int},
                           "rew": {},
                           "done": {}},
                          enable_shared = True)

        self.assertEqual(rb.explore(env_func,policy,post),True)

if __name__ == "__main__":
    unittest.main()
