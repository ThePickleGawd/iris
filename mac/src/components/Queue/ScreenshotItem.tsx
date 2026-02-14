// src/components/ScreenshotItem.tsx
import React from "react"
import { X } from "lucide-react"

interface Screenshot {
  path: string
  preview: string
}

interface ScreenshotItemProps {
  screenshot: Screenshot
  onDelete: (index: number) => void
  index: number
  isLoading: boolean
}

const ScreenshotItem: React.FC<ScreenshotItemProps> = ({
  screenshot,
  onDelete,
  index,
  isLoading
}) => {
  const handleDelete = async () => {
    await onDelete(index)
  }

  return (
    <>
      <div
        className={`screenshot-item ${isLoading ? "" : "group"}`}
      >
        <div className="screenshot-inner">
          {isLoading && (
            <div className="screenshot-loading">
              <div className="screenshot-spinner" />
            </div>
          )}
          <img
            src={screenshot.preview}
            alt="Screenshot"
            className={`screenshot-image ${isLoading ? "opacity-50" : "cursor-pointer group-hover:scale-105 group-hover:brightness-95"}`}
          />
        </div>
        {!isLoading && (
          <button
            onClick={(e) => {
              e.stopPropagation()
              handleDelete()
            }}
            className="screenshot-delete"
            aria-label="Delete screenshot"
          >
            <X size={16} />
          </button>
        )}
      </div>
    </>
  )
}

export default ScreenshotItem
