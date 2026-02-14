import React, { useState, useEffect } from 'react';

interface ModelConfig {
  provider: "ollama" | "claude";
  model: string;
  isOllama: boolean;
}

interface ModelSelectorProps {
  onModelChange?: (provider: "ollama" | "claude", model: string) => void;
  onChatOpen?: () => void;
}

const ModelSelector: React.FC<ModelSelectorProps> = ({ onModelChange, onChatOpen }) => {
  const [currentConfig, setCurrentConfig] = useState<ModelConfig | null>(null);
  const [availableOllamaModels, setAvailableOllamaModels] = useState<string[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [connectionStatus, setConnectionStatus] = useState<'testing' | 'success' | 'error' | null>(null);
  const [errorMessage, setErrorMessage] = useState<string>('');
  const [claudeApiKey, setClaudeApiKey] = useState('');
  const [selectedProvider, setSelectedProvider] = useState<"ollama" | "claude">("claude");
  const [selectedOllamaModel, setSelectedOllamaModel] = useState<string>("");
  const [ollamaUrl, setOllamaUrl] = useState<string>("http://localhost:11434");

  useEffect(() => {
    loadCurrentConfig();
  }, []);

  const loadCurrentConfig = async () => {
    try {
      setIsLoading(true);
      const config = await window.electronAPI.getCurrentLlmConfig();
      setCurrentConfig(config);
      setSelectedProvider(config.provider);
      
      if (config.isOllama) {
        setSelectedOllamaModel(config.model);
        await loadOllamaModels();
      }
    } catch (error) {
      console.error('Error loading current config:', error);
    } finally {
      setIsLoading(false);
    }
  };

  const loadOllamaModels = async () => {
    try {
      const models = await window.electronAPI.getAvailableOllamaModels();
      setAvailableOllamaModels(models);
      
      // Auto-select first model if none selected
      if (models.length > 0 && !selectedOllamaModel) {
        setSelectedOllamaModel(models[0]);
      }
    } catch (error) {
      console.error('Error loading Ollama models:', error);
      setAvailableOllamaModels([]);
    }
  };

  const testConnection = async () => {
    try {
      setConnectionStatus('testing');
      const result = await window.electronAPI.testLlmConnection();
      setConnectionStatus(result.success ? 'success' : 'error');
      if (!result.success) {
        setErrorMessage(result.error || 'Unknown error');
      }
    } catch (error) {
      setConnectionStatus('error');
      setErrorMessage(String(error));
    }
  };

  const handleProviderSwitch = async () => {
    try {
      setConnectionStatus('testing');
      let result;
      
      if (selectedProvider === 'ollama') {
        result = await window.electronAPI.switchToOllama(selectedOllamaModel, ollamaUrl);
      } else {
        result = await window.electronAPI.switchToClaude(claudeApiKey || undefined);
      }

      if (result.success) {
        await loadCurrentConfig();
        setConnectionStatus('success');
        onModelChange?.(selectedProvider, selectedProvider === 'ollama' ? selectedOllamaModel : currentConfig?.model || 'claude-3-5-sonnet-latest');
        // Auto-open chat window after successful model change
        setTimeout(() => {
          onChatOpen?.();
        }, 500);
      } else {
        setConnectionStatus('error');
        setErrorMessage(result.error || 'Switch failed');
      }
    } catch (error) {
      setConnectionStatus('error');
      setErrorMessage(String(error));
    }
  };

  const getStatusColor = () => {
    switch (connectionStatus) {
      case 'testing': return 'text-yellow-600';
      case 'success': return 'text-green-600';
      case 'error': return 'text-red-600';
      default: return 'text-gray-600';
    }
  };

  const getStatusText = () => {
    switch (connectionStatus) {
      case 'testing': return 'Testing connection...';
      case 'success': return 'Connected successfully';
      case 'error': return `Error: ${errorMessage}`;
      default: return 'Ready';
    }
  };

  if (isLoading) {
    return (
      <div className="panel p-4">
        <div className="animate-pulse text-sm text-slate-600">Loading model configuration...</div>
      </div>
    );
  }

  return (
    <div className="panel p-4 space-y-4">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-slate-800">AI Model Selection</h3>
        <div className={`text-xs ${getStatusColor()}`}>
          {getStatusText()}
        </div>
      </div>

      {/* Current Status */}
      {currentConfig && (
        <div className="text-xs text-slate-600 bg-slate-100 p-2 rounded border border-slate-200">
          Current: {currentConfig.provider === 'ollama' ? '🏠' : '☁️'} {currentConfig.model}
        </div>
      )}

      {/* Provider Selection */}
      <div className="space-y-2">
        <label className="text-xs font-medium text-slate-700">Provider</label>
        <div className="flex gap-2">
          <button
            onClick={() => setSelectedProvider('claude')}
            className={`flex-1 px-3 py-2 rounded text-xs transition-all ${
              selectedProvider === 'claude'
                ? 'bg-blue-500 text-white shadow-md'
                : 'bg-slate-100 text-slate-700 hover:bg-slate-200'
            }`}
          >
            ☁️ Claude (Cloud)
          </button>
          <button
            onClick={() => setSelectedProvider('ollama')}
            className={`flex-1 px-3 py-2 rounded text-xs transition-all ${
              selectedProvider === 'ollama'
                ? 'bg-green-500 text-white shadow-md'
                : 'bg-slate-100 text-slate-700 hover:bg-slate-200'
            }`}
          >
            🏠 Ollama (Local)
          </button>
        </div>
      </div>

      {/* Provider-specific settings */}
      {selectedProvider === 'claude' ? (
        <div className="space-y-2">
          <label className="text-xs font-medium text-slate-700">Claude API Key (optional if already set)</label>
          <input
            type="password"
            placeholder="Enter Claude API key..."
            value={claudeApiKey}
            onChange={(e) => setClaudeApiKey(e.target.value)}
            className="w-full px-3 py-2 text-xs bg-white border border-slate-300 rounded focus:outline-none focus:ring-2 focus:ring-teal-700/20"
          />
        </div>
      ) : (
        <div className="space-y-2">
          <div>
            <label className="text-xs font-medium text-slate-700">Ollama URL</label>
            <input
              type="url"
              value={ollamaUrl}
              onChange={(e) => setOllamaUrl(e.target.value)}
              className="w-full px-3 py-2 text-xs bg-white border border-slate-300 rounded focus:outline-none focus:ring-2 focus:ring-teal-700/20"
            />
          </div>
          
          <div>
            <div className="flex items-center gap-2">
              <label className="text-xs font-medium text-slate-700">Model</label>
              <button
                onClick={loadOllamaModels}
                className="px-2 py-1 text-xs bg-slate-100 hover:bg-slate-200 rounded transition-all border border-slate-300"
                title="Refresh models"
              >
                🔄
              </button>
            </div>
            
            {availableOllamaModels.length > 0 ? (
              <select
                value={selectedOllamaModel}
                onChange={(e) => setSelectedOllamaModel(e.target.value)}
                className="w-full px-3 py-2 text-xs bg-white border border-slate-300 rounded focus:outline-none focus:ring-2 focus:ring-teal-700/20"
              >
                {availableOllamaModels.map((model) => (
                  <option key={model} value={model}>
                    {model}
                  </option>
                ))}
              </select>
            ) : (
              <div className="text-xs text-amber-900 bg-amber-100 p-2 rounded border border-amber-200">
                No Ollama models found. Make sure Ollama is running and models are installed.
              </div>
            )}
          </div>
        </div>
      )}

      {/* Action buttons */}
      <div className="flex gap-2 pt-2">
        <button
          onClick={handleProviderSwitch}
          disabled={connectionStatus === 'testing'}
          className="flex-1 px-3 py-2 bg-teal-700 hover:bg-teal-800 disabled:bg-slate-400 text-white text-xs rounded transition-all shadow-sm"
        >
          {connectionStatus === 'testing' ? 'Switching...' : 'Apply Changes'}
        </button>
        
        <button
          onClick={testConnection}
          disabled={connectionStatus === 'testing'}
          className="px-3 py-2 bg-slate-600 hover:bg-slate-700 disabled:bg-slate-400 text-white text-xs rounded transition-all shadow-sm"
        >
          Test
        </button>
      </div>

      {/* Help text */}
      <div className="text-xs text-slate-600 space-y-1">
        <div>💡 <strong>Claude:</strong> Fast, cloud-based, requires API key</div>
        <div>💡 <strong>Ollama:</strong> Private, local, requires Ollama installation</div>
      </div>
    </div>
  );
};

export default ModelSelector;
