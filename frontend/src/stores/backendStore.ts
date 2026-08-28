import { create } from 'zustand';

type BackendStatus = 'ok' | 'unreachable' | 'unknown';

interface BackendState {
  status: BackendStatus;
  setStatus: (status: BackendStatus) => void;
}

const useBackendStore = create<BackendState>((set) => ({
  status: 'unknown',
  setStatus: (status) => set({ status }),
}));

export default useBackendStore;
