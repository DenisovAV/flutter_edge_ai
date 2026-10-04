self.onmessage = async (event) => {
  const { lockName } = event.data;
  try {
    await navigator.locks.request(
      lockName,
      { mode: 'exclusive', ifAvailable: true },
      (lock) => {
        self.postMessage({ acquired: lock !== null });
      },
    );
  } catch (error) {
    self.postMessage({ error: String(error) });
  }
};
