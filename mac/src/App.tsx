import { ToastProvider } from "./components/ui/toast"
import Queue from "./_pages/Queue"
import { ToastViewport } from "@radix-ui/react-toast"
import { useEffect, useRef } from "react"
import { QueryClient, QueryClientProvider } from "react-query"

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: Infinity,
      cacheTime: Infinity
    }
  }
})

const App: React.FC = () => {
  const containerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const container = containerRef.current
    if (!container) return

    const updateHeight = () => {
      const height = container.scrollHeight
      const width = container.scrollWidth
      window.electronAPI?.updateContentDimensions({ width, height })
    }

    const resizeObserver = new ResizeObserver(() => {
      updateHeight()
    })

    // Initial height update
    updateHeight()

    // Observe for changes
    resizeObserver.observe(container)

    // Also update height when view changes
    const mutationObserver = new MutationObserver(() => {
      updateHeight()
    })

    mutationObserver.observe(container, {
      childList: true,
      subtree: true,
      attributes: true,
      characterData: true
    })

    return () => {
      resizeObserver.disconnect()
      mutationObserver.disconnect()
    }
  }, [])

  useEffect(() => {
    const cleanupFunctions = [
      window.electronAPI.onUnauthorized(() => {
        queryClient.removeQueries(["screenshots"])
      }),
      window.electronAPI.onResetView(() => {
        queryClient.invalidateQueries(["screenshots"])
      })
    ]
    return () => cleanupFunctions.forEach((cleanup) => cleanup())
  }, [])

  return (
    <div ref={containerRef} className="app-shell">
      <QueryClientProvider client={queryClient}>
        <ToastProvider>
          <Queue />
          <ToastViewport />
        </ToastProvider>
      </QueryClientProvider>
    </div>
  )
}

export default App
