import React, { useState, useEffect, useRef } from "react"
import { IoLogOutOutline } from "react-icons/io5"

interface SolutionCommandsProps {
  extraScreenshots: any[]
  onTooltipVisibilityChange?: (visible: boolean, height: number) => void
}

const SolutionCommands: React.FC<SolutionCommandsProps> = ({
  extraScreenshots,
  onTooltipVisibilityChange
}) => {
  const [isTooltipVisible, setIsTooltipVisible] = useState(false)
  const tooltipRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (onTooltipVisibilityChange) {
      let tooltipHeight = 0
      if (tooltipRef.current && isTooltipVisible) {
        tooltipHeight = tooltipRef.current.offsetHeight + 10 // Adjust if necessary
      }
      onTooltipVisibilityChange(isTooltipVisible, tooltipHeight)
    }
  }, [isTooltipVisible, onTooltipVisibilityChange])

  const handleMouseEnter = () => {
    setIsTooltipVisible(true)
  }

  const handleMouseLeave = () => {
    setIsTooltipVisible(false)
  }

  return (
    <div>
      <div className="pt-2 w-fit">
        <div className="text-xs liquid-glass-bar py-2 px-4 flex items-center justify-center gap-4 draggable-area">
          {/* Show/Hide */}
          <div className="flex items-center gap-2 whitespace-nowrap">
            <span className="text-[11px] leading-none">Show/Hide</span>
            <div className="flex gap-1">
              <button className="transition-colors rounded-md px-1.5 py-1 text-[11px] leading-none">
                ⌘
              </button>
              <button className="transition-colors rounded-md px-1.5 py-1 text-[11px] leading-none">
                B
              </button>
            </div>
          </div>

          {/* Screenshot */}
          <div className="flex items-center gap-2 whitespace-nowrap">
            <span className="text-[11px] leading-none truncate">
              {extraScreenshots.length === 0
                ? "Screenshot your code"
                : "Screenshot"}
            </span>
            <div className="flex gap-1">
              <button className="transition-colors rounded-md px-1.5 py-1 text-[11px] leading-none">
                ⌘
              </button>
              <button className="transition-colors rounded-md px-1.5 py-1 text-[11px] leading-none">
                H
              </button>
            </div>
          </div>
          {extraScreenshots.length > 0 && (
            <div className="flex items-center gap-2 whitespace-nowrap">
              <span className="text-[11px] leading-none">Debug</span>
              <div className="flex gap-1">
                <button className="transition-colors rounded-md px-1.5 py-1 text-[11px] leading-none">
                  ⌘
                </button>
                <button className="transition-colors rounded-md px-1.5 py-1 text-[11px] leading-none">
                  ↵
                </button>
              </div>
            </div>
          )}

          {/* Start Over */}
          <div className="flex items-center gap-2 whitespace-nowrap">
            <span className="text-[11px] leading-none">Start over</span>
            <div className="flex gap-1">
              <button className="transition-colors rounded-md px-1.5 py-1 text-[11px] leading-none">
                ⌘
              </button>
              <button className="transition-colors rounded-md px-1.5 py-1 text-[11px] leading-none">
                R
              </button>
            </div>
          </div>

          {/* Question Mark with Tooltip */}
          <div
            className="relative inline-block"
            onMouseEnter={handleMouseEnter}
            onMouseLeave={handleMouseLeave}
          >
            {/* Question mark circle */}
            <div className="w-6 h-6 rounded-full bg-slate-700 hover:bg-slate-600 transition-colors flex items-center justify-center cursor-help z-10 border border-slate-500">
              <span className="text-xs text-slate-100">?</span>
            </div>

            {/* Tooltip Content */}
            {isTooltipVisible && (
              <div
                ref={tooltipRef}
                className="absolute top-full right-0 mt-2 w-80"
                style={{ zIndex: 100 }}
              >
                <div className="tooltip-card p-3 text-xs rounded-lg shadow-lg">
                  {/* Tooltip content */}
                  <div className="space-y-4">
                    <h3 className="font-medium whitespace-nowrap">
                      Keyboard Shortcuts
                    </h3>
                    <div className="space-y-3">
                      {/* Toggle Command */}
                      <div className="space-y-1">
                        <div className="flex items-center justify-between">
                          <span className="whitespace-nowrap">
                            Toggle Window
                          </span>
                          <div className="flex gap-1">
                            <span className="bg-slate-700 px-1.5 py-0.5 rounded text-[10px] leading-none">
                              ⌘
                            </span>
                            <span className="bg-slate-700 px-1.5 py-0.5 rounded text-[10px] leading-none">
                              B
                            </span>
                          </div>
                        </div>
                        <p className="text-[10px] leading-relaxed text-slate-300 whitespace-nowrap truncate">
                          Show or hide this window.
                        </p>
                      </div>
                      {/* Screenshot Command */}
                      <div className="space-y-1">
                        <div className="flex items-center justify-between">
                          <span className="whitespace-nowrap">
                            Take Screenshot
                          </span>
                          <div className="flex gap-1">
                            <span className="bg-slate-700 px-1.5 py-0.5 rounded text-[10px] leading-none">
                              ⌘
                            </span>
                            <span className="bg-slate-700 px-1.5 py-0.5 rounded text-[10px] leading-none">
                              H
                            </span>
                          </div>
                        </div>
                        <p className="text-[10px] leading-relaxed text-slate-300 whitespace-nowrap truncate">
                          Capture additional parts of the question or your
                          solution for debugging help. Up to 5 extra screenshots
                          are saved.
                        </p>
                      </div>
                      {/* Debug Command */}
                      <div className="space-y-1">
                        <div className="flex items-center justify-between">
                          <span className="whitespace-nowrap">Debug</span>
                          <div className="flex gap-1">
                            <span className="bg-slate-700 px-1.5 py-0.5 rounded text-[10px] leading-none">
                              ⌘
                            </span>
                            <span className="bg-slate-700 px-1.5 py-0.5 rounded text-[10px] leading-none">
                              ↵
                            </span>
                          </div>
                        </div>
                        <p className="text-[10px] leading-relaxed text-slate-300 whitespace-nowrap truncate">
                          Generate new solutions based on all previous and newly
                          added screenshots.
                        </p>
                      </div>
                      {/* Start Over Command */}
                      <div className="space-y-1">
                        <div className="flex items-center justify-between">
                          <span className="whitespace-nowrap">Start Over</span>
                          <div className="flex gap-1">
                            <span className="bg-slate-700 px-1.5 py-0.5 rounded text-[10px] leading-none">
                              ⌘
                            </span>
                            <span className="bg-slate-700 px-1.5 py-0.5 rounded text-[10px] leading-none">
                              R
                            </span>
                          </div>
                        </div>
                        <p className="text-[10px] leading-relaxed text-slate-300 whitespace-nowrap truncate">
                          Start fresh with a new question.
                        </p>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            )}
          </div>

          {/* Sign Out Button */}
          <button
            className="text-red-500/70 hover:text-red-500/90 transition-colors hover:cursor-pointer"
            title="Sign Out"
            onClick={() => window.electronAPI.quitApp()}
          >
            <IoLogOutOutline className="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
  )
}

export default SolutionCommands
