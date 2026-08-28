import axios from 'axios';

const BACKEND_URL = import.meta.env.VITE_BACKEND_URL || 'http://localhost:8000';

export const checkBackend = async (): Promise<'ok' | 'unreachable'> => {
  try {
    const resp = await axios.get(`${BACKEND_URL}/api/health`, { timeout: 2000 });
    return resp.status === 200 ? 'ok' : 'unreachable';
  } catch {
    return 'unreachable';
  }
};

export const ingestDocument = async (
  title: string,
  content: string,
  metadata?: Record<string, unknown>
) => {
  return axios.post(`${BACKEND_URL}/api/ingest`, { title, content, metadata });
};

export const queryRAG = async (query: string, topK: number = 5) => {
  return axios.post(`${BACKEND_URL}/api/query`, { query, top_k: topK });
};
