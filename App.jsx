import React, { useState, useEffect, useCallback } from 'react';
import {
  BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer, AreaChart, Area
} from 'recharts';
import {
  LayoutDashboard, Users, Server, Zap, BarChart3, History, AlertCircle,
  ChevronDown, ChevronRight, Search, Bell, CheckCircle, XCircle,
  Power, PowerOff, RefreshCw, Filter, Calendar,
  ToggleLeft, ToggleRight, Trash2, TrendingUp, DollarSign
} from 'lucide-react';

// ==============================================================================
// API CONFIGURATION
// ==============================================================================

const API_CONFIG = {
  BASE_URL: process.env.REACT_APP_API_URL || 'http://localhost:5000',
};

// ==============================================================================
// API CLIENT (FIXED)
// ==============================================================================

class APIClient {
  constructor(baseUrl) {
    this.baseUrl = baseUrl;
  }

  async request(endpoint, options = {}) {
    try {
      const response = await fetch(`${this.baseUrl}${endpoint}`, {
        ...options,
        headers: {
          'Content-Type': 'application/json',
          ...options.headers,
        },
      });

      if (!response.ok) {
        const error = await response.json().catch(() => ({}));
        throw new Error(error.error || `API Error: ${response.status} ${response.statusText}`);
      }

      return await response.json();
    } catch (error) {
      console.error(`API Request Failed: ${endpoint}`, error);
      throw error;
    }
  }

  // Admin APIs
  async getGlobalStats() {
    return this.request('/api/admin/stats');
  }

  async getAllClients() {
    return this.request('/api/admin/clients');
  }

  async getRecentActivity() {
    return this.request('/api/admin/activity');
  }

  // Client APIs
  async getClientDetails(clientId) {
    return this.request(`/api/client/${clientId}`);
  }

  async getAgents(clientId) {
    return this.request(`/api/client/${clientId}/agents`);
  }

  async toggleAgent(agentId, enabled) {
    return this.request(`/api/client/agents/${agentId}/toggle-enabled`, {
      method: 'POST',
      body: JSON.stringify({ enabled }),
    });
  }

  async updateAgentSettings(agentId, settings) {
    return this.request(`/api/client/agents/${agentId}/settings`, {
      method: 'POST',
      body: JSON.stringify(settings),
    });
  }

  async getInstances(clientId) {
    return this.request(`/api/client/${clientId}/instances`);
  }

  async getInstancePricing(instanceId) {
    return this.request(`/api/client/instances/${instanceId}/pricing`);
  }

  // FIXED: Force switch now properly queues command
  async forceSwitch(instanceId, body) {
    return this.request(`/api/client/instances/${instanceId}/force-switch`, {
      method: 'POST',
      body: JSON.stringify(body),
    });
  }

  async getSavings(clientId, range = 'monthly') {
    return this.request(`/api/client/${clientId}/savings?range=${range}`);
  }

  // FIXED: Proper query parameter format
  async getSwitchHistory(clientId, instanceId = null) {
    const query = instanceId ? `?instance_id=${instanceId}` : '';
    return this.request(`/api/client/${clientId}/switch-history${query}`);
  }
}

const api = new APIClient(API_CONFIG.BASE_URL);

// ==============================================================================
// SHARED COMPONENTS
// ==============================================================================

const LoadingSpinner = ({ size = 'md' }) => {
  const sizeClasses = {
    sm: 'w-4 h-4',
    md: 'w-8 h-8',
    lg: 'w-12 h-12',
  };
  return (
    <div className={`animate-spin rounded-full border-t-2 border-b-2 border-blue-500 ${sizeClasses[size]}`}></div>
  );
};

const StatCard = ({ title, value, icon, change, changeType }) => (
  <div className="bg-white p-4 rounded-lg shadow-md flex items-center justify-between hover:shadow-lg transition-shadow">
    <div>
      <p className="text-sm font-medium text-gray-500">{title}</p>
      <p className="text-2xl font-semibold text-gray-800">{value}</p>
      {change && (
        <p className={`text-xs ${changeType === 'positive' ? 'text-green-500' : 'text-red-500'}`}>
          {change}
        </p>
      )}
    </div>
    <div className="bg-blue-100 text-blue-600 p-3 rounded-full">
      {icon}
    </div>
  </div>
);

const CustomTooltip = ({ active, payload, label }) => {
  if (active && payload && payload.length) {
    return (
      <div className="bg-white p-3 rounded-lg shadow-lg border border-gray-200">
        <p className="font-semibold text-gray-700">{label}</p>
        {payload.map((entry, index) => (
          <p key={`item-${index}`} style={{ color: entry.color }} className="text-sm">
            {`${entry.name}: ${entry.value.toLocaleString(undefined, { style: 'currency', currency: 'USD' })}`}
          </p>
        ))}
      </div>
    );
  }
  return null;
};

const SavingsComparisonChart = ({ data }) => (
  <div className="bg-white p-4 rounded-lg shadow-md h-80">
    <h3 className="text-lg font-semibold text-gray-800 mb-4">"Always On-Demand" vs "Our Model" Cost</h3>
    <ResponsiveContainer width="100%" height="100%">
      <AreaChart data={data} margin={{ top: 5, right: 20, left: 10, bottom: 20 }}>
        <CartesianGrid strokeDasharray="3 3" vertical={false} />
        <XAxis dataKey="name" tick={{ fontSize: 12 }} />
        <YAxis tickFormatter={(value) => `$${value / 1000}k`} tick={{ fontSize: 12 }} />
        <Tooltip content={<CustomTooltip />} />
        <Legend verticalAlign="top" height={36} />
        <Area type="monotone" dataKey="onDemandCost" stackId="1" stroke="#ef4444" fill="#fecaca" name="Always On-Demand Cost" />
        <Area type="monotone" dataKey="modelCost" stackId="1" stroke="#3b82f6" fill="#bfdbfe" name="Our Model Cost" />
      </AreaChart>
    </ResponsiveContainer>
  </div>
);

const MonthlySavingsChart = ({ data }) => (
  <div className="bg-white p-4 rounded-lg shadow-md h-80">
    <h3 className="text-lg font-semibold text-gray-800 mb-4">Monthly Savings</h3>
    <ResponsiveContainer width="100%" height="100%">
      <BarChart data={data} margin={{ top: 5, right: 20, left: 10, bottom: 20 }}>
        <CartesianGrid strokeDasharray="3 3" vertical={false} />
        <XAxis dataKey="name" tick={{ fontSize: 12 }} />
        <YAxis tickFormatter={(value) => `$${value / 1000}k`} tick={{ fontSize: 12 }} />
        <Tooltip content={<CustomTooltip />} />
        <Legend verticalAlign="top" height={36} />
        <Bar dataKey="savings" fill="#34d399" name="Realized Savings" />
      </BarChart>
    </ResponsiveContainer>
  </div>
);

const SwitchHistoryTable = ({ history, loading }) => (
  <div className="bg-white p-4 rounded-lg shadow-md mt-6">
    <h3 className="text-lg font-semibold text-gray-800 mb-4">Switch History</h3>
    <div className="overflow-x-auto">
      <table className="min-w-full divide-y divide-gray-200">
        <thead className="bg-gray-50">
          <tr>
            <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Timestamp</th>
            <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Instance ID</th>
            <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">From</th>
            <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">To</th>
            <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Trigger</th>
            <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Price</th>
            <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Savings Impact</th>
          </tr>
        </thead>
        <tbody className="bg-white divide-y divide-gray-200">
          {loading ? (
            <tr><td colSpan="7" className="text-center p-4"><LoadingSpinner /></td></tr>
          ) : history.length === 0 ? (
             <tr><td colSpan="7" className="text-center p-4 text-gray-500">No switch history found.</td></tr>
          ) : (
            history.map(sw => (
              <tr key={sw.id} className="hover:bg-gray-50">
                <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-700">{new Date(sw.timestamp).toLocaleString()}</td>
                <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-500 font-mono">{sw.instanceId}</td>
                <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-700">
                  <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${sw.fromMode === 'ondemand' ? 'bg-red-100 text-red-700' : 'bg-green-100 text-green-700'}`}>{sw.fromMode}</span>
                  <div className="text-xs text-gray-400">{sw.fromPool}</div>
                </td>
                <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-700">
                   <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${sw.toMode === 'ondemand' ? 'bg-red-100 text-red-700' : 'bg-green-100 text-green-700'}`}>{sw.toMode}</span>
                  <div className="text-xs text-gray-400">{sw.toPool}</div>
                </td>
                <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-500 capitalize">{sw.trigger}</td>
                <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-500">${sw.price.toFixed(4)}</td>
                <td className={`px-4 py-3 whitespace-nowrap text-sm font-medium ${sw.savingsImpact >= 0 ? 'text-green-600' : 'text-red-600'}`}>
                  ${sw.savingsImpact.toFixed(4)}
                </td>
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  </div>
);

// ==============================================================================
// ADMIN COMPONENTS
// ==============================================================================

const AdminSidebar = ({ clients, onSelectClient, activeClientId, onSelectPage, activePage }) => (
  <div className="w-64 bg-gray-900 text-white h-screen flex flex-col fixed top-0 left-0">
    <div className="p-4 border-b border-gray-700">
      <h1 className="text-xl font-bold text-white">Spot Optimizer</h1>
      <p className="text-xs text-gray-400 mt-1">Admin Dashboard</p>
    </div>
    <nav className="p-2">
      <ul>
        {['Overview', 'Clients', 'Agents', 'Instances', 'Savings', 'Switch History', 'Events'].map(item => {
          const icons = {
            Overview: <LayoutDashboard size={18} />,
            Clients: <Users size={18} />,
            Agents: <Server size={18} />,
            Instances: <Zap size={18} />,
            Savings: <BarChart3 size={18} />,
            SwitchHistory: <History size={18} />,
            Events: <AlertCircle size={18} />,
          };
          const pageId = item.toLowerCase().replace(' ', '');
          const isActive = activePage === pageId;
          return (
            <li key={item}>
              <button
                onClick={() => onSelectPage(pageId)}
                className={`flex items-center w-full px-3 py-2.5 rounded-md text-sm font-medium ${
                  isActive ? 'bg-gray-700 text-white' : 'text-gray-300 hover:bg-gray-700 hover:text-white'
                }`}
              >
                {icons[item.replace(' ', '')]}
                <span className="ml-3">{item}</span>
              </button>
            </li>
          );
        })}
      </ul>
    </nav>
    
    <div className="p-2 mt-4 border-t border-gray-700 flex-1 overflow-y-auto">
      <h2 className="px-3 py-2 text-xs font-semibold text-gray-400 uppercase tracking-wider">Clients</h2>
      <ul className="mt-1">
        {clients.length === 0 ? (
          <div className="flex justify-center p-4">
            <LoadingSpinner size="sm" />
          </div>
        ) : (
          clients.map(client => (
            <li key={client.id}>
              <button
                onClick={() => onSelectClient(client.id)}
                className={`flex items-center justify-between w-full px-3 py-2.5 rounded-md text-sm ${
                  activeClientId === client.id ? 'bg-blue-600 text-white' : 'text-gray-300 hover:bg-gray-700 hover:text-white'
                }`}
              >
                <span className="truncate">{client.name}</span>
                <span className={`w-2 h-2 rounded-full ${client.status === 'active' ? 'bg-green-400' : 'bg-red-400'}`}></span>
              </button>
            </li>
          ))
        )}
      </ul>
    </div>
  </div>
);

const AdminHeader = ({ stats, onSearch }) => (
  <header className="bg-white border-b border-gray-200 p-4">
    <div className="flex items-center justify-between">
      <h2 className="text-xl font-semibold text-gray-800">Admin Dashboard</h2>
      <div className="flex items-center space-x-4">
        <div className="relative">
          <Search size={18} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" />
          <input
            type="text"
            placeholder="Search clients..."
            className="pl-10 pr-4 py-2 w-64 rounded-md border border-gray-300 focus:outline-none focus:ring-2 focus:ring-blue-500"
            onChange={(e) => onSearch(e.target.value)}
          />
        </div>
        <button className="text-gray-500 hover:text-gray-700">
          <Bell size={20} />
        </button>
        <div className="flex items-center space-x-2 text-sm">
          <span className={`w-3 h-3 rounded-full ${stats?.backendHealth === 'Healthy' ? 'bg-green-500' : 'bg-red-500'}`}></span>
          <span className="text-gray-600">Backend: {stats?.backendHealth || '...'}</span>
        </div>
      </div>
    </div>
    
    <div className="mt-4">
      {stats ? (
        <div className="grid grid-cols-6 gap-4">
          <div className="bg-gray-50 p-3 rounded-lg text-center">
            <p className="text-xs text-gray-500 uppercase">Total Accounts</p>
            <p className="text-lg font-semibold text-gray-800">{stats.totalAccounts}</p>
          </div>
          <div className="bg-gray-50 p-3 rounded-lg text-center">
            <p className="text-xs text-gray-500 uppercase">Agents Online</p>
            <p className="text-lg font-semibold text-gray-800">
              <span className="text-green-600">{stats.agentsOnline}</span> / {stats.agentsTotal}
            </p>
          </div>
          <div className="bg-gray-50 p-3 rounded-lg text-center">
            <p className="text-xs text-gray-500 uppercase">Pools Covered</p>
            <p className="text-lg font-semibold text-gray-800">{stats.poolsCovered}</p>
          </div>
          <div className="bg-gray-50 p-3 rounded-lg text-center">
            <p className="text-xs text-gray-500 uppercase">Total Savings</p>
            <p className="text-lg font-semibold text-green-600">
              {stats.totalSavings.toLocaleString('en-US', { style: 'currency', currency: 'USD' })}
            </p>
          </div>
          <div className="bg-gray-50 p-3 rounded-lg text-center">
            <p className="text-xs text-gray-500 uppercase">Total Switches</p>
            <p className="text-lg font-semibold text-gray-800">{stats.totalSwitches}</p>
          </div>
           <div className="bg-gray-50 p-3 rounded-lg text-center">
            <p className="text-xs text-gray-500 uppercase">Manual / Model</p>
            <p className="text-lg font-semibold text-gray-800">{stats.manualSwitches} / {stats.modelSwitches}</p>
          </div>
        </div>
      ) : (
        <div className="flex justify-center p-4"><LoadingSpinner /></div>
      )}
    </div>
  </header>
);

// FIXED: Activity now shows real data from API
const AdminOverview = () => {
  const [activity, setActivity] = useState([]);
  const [stats, setStats] = useState(null);
  const [loading, setLoading] = useState(true);
  
  useEffect(() => {
    const loadData = async () => {
      setLoading(true);
      try {
        const [activityData, statsData] = await Promise.all([
          api.getRecentActivity(),
          api.getGlobalStats()
        ]);
        setActivity(activityData);
        setStats(statsData);
      } catch (error) {
        console.error('Failed to load overview data:', error);
      } finally {
        setLoading(false);
      }
    };
    loadData();
    
    // Auto-refresh every 30 seconds
    const interval = setInterval(loadData, 30000);
    return () => clearInterval(interval);
  }, []);

  const icons = {
    switch: <RefreshCw size={16} className="text-blue-500" />,
    agent: <Server size={16} className="text-red-500" />,
    event: <AlertCircle size={16} className="text-yellow-500" />,
  };
  
  return (
    <div>
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        <StatCard title="Total Clients" value={stats?.totalAccounts || 0} icon={<Users size={24} />} />
        <StatCard title="Agents Online" value={stats ? `${stats.agentsOnline} / ${stats.agentsTotal}` : '...'} icon={<Server size={24} />} />
        <StatCard title="Pools Covered" value={stats?.poolsCovered || 0} icon={<Zap size={24} />} />
        <StatCard title="Total Savings (YTD)" value={stats?.totalSavings.toLocaleString('en-US', { style: 'currency', currency: 'USD' }) || '$0'} icon={<BarChart3 size={24} />} />
      </div>
      
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 mt-6">
        <div className="bg-white p-4 rounded-lg shadow-md h-80">
          <h3 className="text-lg font-semibold text-gray-800 mb-4">System Activity</h3>
          {loading ? (
            <div className="flex justify-center items-center h-full"><LoadingSpinner /></div>
          ) : activity.length === 0 ? (
            <div className="flex justify-center items-center h-full text-gray-500">
              No recent activity
            </div>
          ) : (
            <ul className="space-y-4 overflow-y-auto h-64">
              {activity.map(item => (
                <li key={item.id} className="flex items-start space-x-3">
                  <span className="flex-shrink-0 w-8 h-8 flex items-center justify-center bg-gray-100 rounded-full">
                    {icons[item.type] || <AlertCircle size={16} className="text-gray-500" />}
                  </span>
                  <div>
                    <p className="text-sm text-gray-700">{item.text}</p>
                    <p className="text-xs text-gray-400">{item.time}</p>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
        
        <div className="bg-white p-4 rounded-lg shadow-md h-80">
          <h3 className="text-lg font-semibold text-gray-800 mb-4">Quick Stats</h3>
          <div className="space-y-4">
            <div className="flex justify-between items-center p-3 bg-gray-50 rounded-lg">
              <span className="text-sm text-gray-600">Switch Success Rate</span>
              <span className="text-lg font-semibold text-green-600">
                {stats ? ((stats.totalSwitches - stats.manualSwitches) / Math.max(stats.totalSwitches, 1) * 100).toFixed(1) : 0}%
              </span>
            </div>
            <div className="flex justify-between items-center p-3 bg-gray-50 rounded-lg">
              <span className="text-sm text-gray-600">Avg Spot Usage</span>
              <span className="text-lg font-semibold text-blue-600">87%</span>
            </div>
            <div className="flex justify-between items-center p-3 bg-gray-50 rounded-lg">
              <span className="text-sm text-gray-600">Active Instances</span>
              <span className="text-lg font-semibold text-gray-800">{stats?.poolsCovered || 0}</span>
            </div>
            <div className="flex justify-between items-center p-3 bg-gray-50 rounded-lg">
              <span className="text-sm text-gray-600">Avg Savings/Month</span>
              <span className="text-lg font-semibold text-green-600">
                {stats ? (stats.totalSavings / 12).toLocaleString('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }) : '$0'}
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

// ==============================================================================
// CLIENT DETAIL TABS
// ==============================================================================

const ClientOverviewTab = ({ clientId }) => {
  const [client, setClient] = useState(null);
  const [history, setHistory] = useState([]);
  const [savingsData, setSavingsData] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    const loadData = async () => {
      setLoading(true);
      setError(null);
      try {
        const [clientData, historyData, savings] = await Promise.all([
          api.getClientDetails(clientId),
          api.getSwitchHistory(clientId),
          api.getSavings(clientId, 'monthly')
        ]);
        setClient(clientData);
        setHistory(historyData.slice(0, 5));
        setSavingsData(savings);
      } catch (err) {
        setError(err.message);
      } finally {
        setLoading(false);
      }
    };
    loadData();
  }, [clientId]);

  if (loading) {
    return <div className="flex justify-center items-center h-64"><LoadingSpinner /></div>;
  }

  if (error) {
    return <div className="bg-red-50 border border-red-200 text-red-700 p-4 rounded-lg">Error: {error}</div>;
  }

  if (!client) {
    return <div className="text-gray-500 p-4">No client data available</div>;
  }

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        <StatCard title="Instances Monitored" value={client.instances} icon={<Zap size={24} />} />
        <StatCard title="Agents Online" value={`${client.agentsOnline} / ${client.agentsTotal}`} icon={<Server size={24} />} />
        <StatCard title="Monthly Savings" value="$...k" icon={<BarChart3 size={24} />} />
        <StatCard title="Lifetime Savings" value={client.totalSavings.toLocaleString('en-US', { style: 'currency', currency: 'USD' })} icon={<BarChart3 size={24} />} />
      </div>
      
      <SavingsComparisonChart data={savingsData} />
      
      <SwitchHistoryTable history={history} loading={false} />
    </div>
  );
};

const ClientAgentsTab = ({ clientId }) => {
  const [agents, setAgents] = useState([]);
  const [loading, setLoading] = useState(true);
  const [toggling, setToggling] = useState(null);
  const [updatingSettings, setUpdatingSettings] = useState(null);
  const [error, setError] = useState(null);

  const loadAgents = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await api.getAgents(clientId);
      setAgents(data);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, [clientId]);

  useEffect(() => {
    loadAgents();
  }, [loadAgents]);

  const handleToggle = async (agentId, currentEnabled) => {
    setToggling(agentId);
    try {
      await api.toggleAgent(agentId, !currentEnabled);
      await loadAgents();
    } catch (error) {
      console.error('Failed to toggle agent:', error);
      alert('Failed to toggle agent. Please try again.');
    } finally {
      setToggling(null);
    }
  };

  const handleSettingToggle = async (agentId, setting, currentValue) => {
    setUpdatingSettings(agentId);
    try {
      const updates = { [setting]: !currentValue };
      await api.updateAgentSettings(agentId, updates);
      await loadAgents();
    } catch (error) {
      console.error('Failed to update settings:', error);
      alert('Failed to update settings. Please try again.');
    } finally {
      setUpdatingSettings(null);
    }
  };

  if (error) {
    return <div className="bg-red-50 border border-red-200 text-red-700 p-4 rounded-lg">Error: {error}</div>;
  }
  
  return (
    <div className="bg-white p-4 rounded-lg shadow-md">
      <h3 className="text-lg font-semibold text-gray-800 mb-4">Agents</h3>
      <div className="overflow-x-auto">
        <table className="min-w-full divide-y divide-gray-200">
          <thead className="bg-gray-50">
            <tr>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Agent ID</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Status</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Last Heartbeat</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Instances</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Enabled</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Auto Switch</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Auto Terminate</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Actions</th>
            </tr>
          </thead>
          <tbody className="bg-white divide-y divide-gray-200">
            {loading ? (
              <tr><td colSpan="8" className="text-center p-4"><LoadingSpinner /></td></tr>
            ) : agents.length === 0 ? (
               <tr><td colSpan="8" className="text-center p-4 text-gray-500">No agents found for this client.</td></tr>
            ) : (
              agents.map(agent => (
                <tr key={agent.id} className="hover:bg-gray-50">
                  <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-500 font-mono">{agent.id}</td>
                  <td className="px-4 py-3 whitespace-nowrap text-sm">
                    <span className={`flex items-center space-x-1.5 ${agent.status === 'online' ? 'text-green-600' : 'text-red-600'}`}>
                      {agent.status === 'online' ? <CheckCircle size={14} /> : <XCircle size={14} />}
                      <span className="capitalize">{agent.status}</span>
                    </span>
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-500">
                    {agent.lastHeartbeat ? new Date(agent.lastHeartbeat).toLocaleString() : 'Never'}
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-500">{agent.instanceCount}</td>
                  <td className="px-4 py-3 whitespace-nowrap text-sm">
                    <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${agent.enabled ? 'bg-green-100 text-green-700' : 'bg-gray-100 text-gray-700'}`}>
                      {agent.enabled ? 'Enabled' : 'Disabled'}
                    </span>
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap text-sm">
                    <button
                      onClick={() => handleSettingToggle(agent.id, 'auto_switch_enabled', agent.auto_switch_enabled)}
                      disabled={updatingSettings === agent.id}
                      className={`flex items-center space-x-1 px-2 py-1 rounded-md text-xs font-medium transition-colors ${
                        agent.auto_switch_enabled 
                          ? 'bg-blue-100 text-blue-700 hover:bg-blue-200' 
                          : 'bg-gray-100 text-gray-600 hover:bg-gray-200'
                      } disabled:opacity-50`}
                      title="Toggle automatic instance switching"
                    >
                      {updatingSettings === agent.id ? (
                        <LoadingSpinner size="sm" />
                      ) : agent.auto_switch_enabled ? (
                        <><ToggleRight size={16} /> <span>ON</span></>
                      ) : (
                        <><ToggleLeft size={16} /> <span>OFF</span></>
                      )}
                    </button>
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap text-sm">
                    <button
                      onClick={() => handleSettingToggle(agent.id, 'auto_terminate_enabled', agent.auto_terminate_enabled)}
                      disabled={updatingSettings === agent.id}
                      className={`flex items-center space-x-1 px-2 py-1 rounded-md text-xs font-medium transition-colors ${
                        agent.auto_terminate_enabled 
                          ? 'bg-red-100 text-red-700 hover:bg-red-200' 
                          : 'bg-gray-100 text-gray-600 hover:bg-gray-200'
                      } disabled:opacity-50`}
                      title="Toggle automatic termination of old instances"
                    >
                      {updatingSettings === agent.id ? (
                        <LoadingSpinner size="sm" />
                      ) : agent.auto_terminate_enabled ? (
                        <><Trash2 size={16} /> <span>ON</span></>
                      ) : (
                        <><ToggleLeft size={16} /> <span>OFF</span></>
                      )}
                    </button>
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap text-sm">
                    <button
                      onClick={() => handleToggle(agent.id, agent.enabled)}
                      disabled={toggling === agent.id}
                      className={`flex items-center justify-center px-3 py-1.5 rounded-md text-xs font-medium text-white ${
                        agent.enabled ? 'bg-red-500 hover:bg-red-600' : 'bg-green-500 hover:bg-green-600'
                      } disabled:bg-gray-300`}
                    >
                      {toggling === agent.id ? (
                        <LoadingSpinner size="sm" />
                      ) : (
                        agent.enabled ? <PowerOff size={14} className="mr-1" /> : <Power size={14} className="mr-1" />
                      )}
                      {toggling === agent.id ? '...' : (agent.enabled ? 'Disable' : 'Enable')}
                    </button>
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
};

// FIXED: Instance Detail Panel with proper force-switch implementation
const InstanceDetailPanel = ({ instanceId, clientId }) => {
  const [pricing, setPricing] = useState(null);
  const [history, setHistory] = useState([]);
  const [loading, setLoading] = useState(true);
  const [switching, setSwitching] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    const loadData = async () => {
      setLoading(true);
      setError(null);
      try {
        const [pricingData, historyData] = await Promise.all([
          api.getInstancePricing(instanceId),
          api.getSwitchHistory(clientId, instanceId)
        ]);
        setPricing(pricingData);
        setHistory(historyData);
      } catch (err) {
        setError(err.message);
      } finally {
        setLoading(false);
      }
    };
    loadData();
  }, [instanceId, clientId]);

  // FIXED: Proper force-switch implementation with user feedback
  const handleForceSwitch = async (body) => {
    const target = body.target === 'ondemand' ? 'On-Demand' : `Pool ${body.pool_id}`;
    
    if (!window.confirm(`Are you sure you want to force switch to ${target}? This will queue a manual switch command for the agent.`)) {
      return;
    }

    setSwitching(body.target === 'ondemand' ? 'ondemand' : body.pool_id);
    try {
      const result = await api.forceSwitch(instanceId, body);
      alert(`✓ Switch command queued successfully!\n\nThe agent will execute this switch on its next check cycle (within ~1 minute).\n\nTarget: ${target}`);
      console.log('Force switch result:', result);
    } catch (e) {
      console.error('Switch failed', e);
      alert(`✗ Switch command failed: ${e.message}\n\nPlease check that the agent is online and try again.`);
    } finally {
      setSwitching(null);
    }
  };

  if (loading) {
    return <tr className="bg-gray-50"><td colSpan="9" className="p-4"><div className="flex justify-center"><LoadingSpinner /></div></td></tr>;
  }

  if (error) {
    return <tr className="bg-red-50"><td colSpan="9" className="p-4 text-red-700">Error: {error}</td></tr>;
  }

  if (!pricing) {
    return <tr className="bg-gray-50"><td colSpan="9" className="p-4 text-gray-500">No pricing data available</td></tr>;
  }
  
  return (
    <tr className="bg-gray-100">
      <td colSpan="9" className="p-6">
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <div className="lg:col-span-1 space-y-4">
            <h4 className="text-md font-semibold text-gray-800">Live Pricing</h4>
            <div className="bg-white p-4 rounded-lg border border-red-200 shadow-sm">
              <div className="flex justify-between items-center">
                <div>
                  <p className="text-sm font-medium text-red-700">On-Demand</p>
                  <p className="text-xl font-bold text-gray-800">${pricing.onDemand.price.toFixed(4)}</p>
                </div>
                <button
                  onClick={() => handleForceSwitch({ target: 'ondemand' })}
                  disabled={switching === 'ondemand'}
                  className="px-3 py-1.5 text-xs font-medium text-white bg-red-500 rounded-md hover:bg-red-600 disabled:bg-gray-300 disabled:cursor-not-allowed"
                >
                  {switching === 'ondemand' ? <LoadingSpinner size="sm" /> : 'Force Fallback'}
                </button>
              </div>
            </div>
            <div className="space-y-3 max-h-48 overflow-y-auto pr-2">
              {pricing.pools.map(pool => (
                <div key={pool.id} className="bg-white p-3 rounded-lg border border-gray-200">
                  <div className="flex justify-between items-center">
                    <div>
                      <p className="text-sm font-medium text-blue-700 font-mono">{pool.id}</p>
                      <p className="text-lg font-bold text-gray-800">${pool.price.toFixed(4)}</p>
                      <p className="text-xs font-medium text-green-600">{pool.savings.toFixed(2)}% Savings</p>
                    </div>
                    <button
                      onClick={() => handleForceSwitch({ target: 'pool', pool_id: pool.id })}
                      disabled={switching === pool.id}
                      className="px-3 py-1.5 text-xs font-medium text-white bg-blue-500 rounded-md hover:bg-blue-600 disabled:bg-gray-300 disabled:cursor-not-allowed"
                    >
                      {switching === pool.id ? <LoadingSpinner size="sm" /> : 'Force Switch'}
                    </button>
                  </div>
                </div>
              ))}
            </div>
          </div>
          
          <div className="lg:col-span-2 bg-white p-4 rounded-lg shadow-sm">
             <h4 className="text-md font-semibold text-gray-800 mb-2">Instance Switch History</h4>
             <div className="max-h-60 overflow-y-auto">
                <SwitchHistoryTable history={history} loading={false} />
             </div>
          </div>
        </div>
      </td>
    </tr>
  );
};

const ClientInstancesTab = ({ clientId }) => {
  const [instances, setInstances] = useState([]);
  const [loading, setLoading] = useState(true);
  const [selectedInstanceId, setSelectedInstanceId] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    const loadInstances = async () => {
      setLoading(true);
      setError(null);
      try {
        const data = await api.getInstances(clientId);
        setInstances(data);
      } catch (err) {
        setError(err.message);
      } finally {
        setLoading(false);
      }
    };
    loadInstances();
  }, [clientId]);

  const toggleInstanceDetail = (instanceId) => {
    setSelectedInstanceId(prevId => prevId === instanceId ? null : instanceId);
  };

  if (error) {
    return <div className="bg-red-50 border border-red-200 text-red-700 p-4 rounded-lg">Error: {error}</div>;
  }
  
  return (
    <div className="bg-white p-4 rounded-lg shadow-md">
      <h3 className="text-lg font-semibold text-gray-800 mb-4">Instances</h3>
      <div className="overflow-x-auto">
        <table className="min-w-full divide-y divide-gray-200">
          <thead className="bg-gray-50">
            <tr>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider"></th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Instance ID</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Type</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">AZ</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Mode</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Pool ID</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Prices (Spot / OD)</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Savings</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Last Switch</th>
            </tr>
          </thead>
          <tbody className="bg-white divide-y divide-gray-200">
            {loading ? (
              <tr><td colSpan="9" className="text-center p-4"><LoadingSpinner /></td></tr>
            ) : instances.length === 0 ? (
               <tr><td colSpan="9" className="text-center p-4 text-gray-500">No instances found.</td></tr>
            ) : (
              instances.map(inst => (
                <React.Fragment key={inst.id}>
                  <tr className="hover:bg-gray-50 cursor-pointer" onClick={() => toggleInstanceDetail(inst.id)}>
                    <td className="px-4 py-3">
                      {selectedInstanceId === inst.id ? <ChevronDown size={16} /> : <ChevronRight size={16} />}
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-500 font-mono">{inst.id}</td>
                    <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-700">{inst.type}</td>
                    <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-500">{inst.az}</td>
                    <td className="px-4 py-3 whitespace-nowrap text-sm">
                       <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${inst.mode === 'ondemand' ? 'bg-red-100 text-red-700' : 'bg-green-100 text-green-700'}`}>{inst.mode}</span>
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-500 font-mono">{inst.poolId}</td>
                    <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-500">
                      ${inst.spotPrice.toFixed(4)} / ${inst.onDemandPrice.toFixed(4)}
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap text-sm font-medium text-green-600">
                      {(((inst.onDemandPrice - inst.spotPrice) / inst.onDemandPrice) * 100).toFixed(1)}%
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-500">
                      {inst.lastSwitch ? new Date(inst.lastSwitch).toLocaleString() : 'Never'}
                    </td>
                  </tr>
                  {selectedInstanceId === inst.id && <InstanceDetailPanel instanceId={inst.id} clientId={clientId} />}
                </React.Fragment>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
};

const ClientSavingsTab = ({ clientId }) => {
  const [savingsData, setSavingsData] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [totalSavings, setTotalSavings] = useState(0);

  useEffect(() => {
    const loadData = async () => {
      setLoading(true);
      setError(null);
      try {
        const [data, clientData] = await Promise.all([
          api.getSavings(clientId, 'monthly'),
          api.getClientDetails(clientId)
        ]);
        setSavingsData(data);
        setTotalSavings(clientData.totalSavings);
      } catch (err) {
        setError(err.message);
      } finally {
        setLoading(false);
      }
    };
    loadData();
  }, [clientId]);

  if (loading) {
    return <div className="flex justify-center items-center h-64"><LoadingSpinner /></div>;
  }

  if (error) {
    return <div className="bg-red-50 border border-red-200 text-red-700 p-4 rounded-lg">Error: {error}</div>;
  }
  
  return (
    <div className="space-y-6">
      <StatCard 
        title="Total Savings" 
        value={totalSavings.toLocaleString('en-US', { style: 'currency', currency: 'USD' })} 
        icon={<BarChart3 size={24} />} 
      />
      <SavingsComparisonChart data={savingsData} />
      <MonthlySavingsChart data={savingsData} />
    </div>
  );
};

const ClientSwitchHistoryTab = ({ clientId }) => {
  const [history, setHistory] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    const loadData = async () => {
      setLoading(true);
      setError(null);
      try {
        const data = await api.getSwitchHistory(clientId);
        setHistory(data);
      } catch (err) {
        setError(err.message);
      } finally {
        setLoading(false);
      }
    };
    loadData();
  }, [clientId]);

  if (error) {
    return <div className="bg-red-50 border border-red-200 text-red-700 p-4 rounded-lg">Error: {error}</div>;
  }
  
  return (
    <div>
      <div className="flex justify-between items-center mb-4">
        <h2 className="text-xl font-semibold">Full Switch History</h2>
        <div className="flex space-x-2">
            <button className="flex items-center px-3 py-1.5 border border-gray-300 rounded-md text-sm text-gray-700 hover:bg-gray-50">
              <Filter size={14} className="mr-1" /> Filter
            </button>
            <button className="flex items-center px-3 py-1.5 border border-gray-300 rounded-md text-sm text-gray-700 hover:bg-gray-50">
              <Calendar size={14} className="mr-1" /> Date Range
            </button>
        </div>
      </div>
      <SwitchHistoryTable history={history} loading={loading} />
    </div>
  );
};

// ==============================================================================
// ADMIN DASHBOARD APP
// ==============================================================================

const AdminDashboardApp = () => {
  const [allClients, setAllClients] = useState([]);
  const [filteredClients, setFilteredClients] = useState([]);
  const [globalStats, setGlobalStats] = useState(null);
  const [selectedClientId, setSelectedClientId] = useState(null);
  const [activePage, setActivePage] = useState('overview');
  const [client, setClient] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const loadData = async () => {
      setLoading(true);
      try {
        const [clientsData, statsData] = await Promise.all([
          api.getAllClients(),
          api.getGlobalStats()
        ]);
        setAllClients(clientsData);
        setFilteredClients(clientsData);
        setGlobalStats(statsData);
      } catch (error) {
        console.error('Failed to load admin data:', error);
      } finally {
        setLoading(false);
      }
    };
    loadData();
    
    // Auto-refresh every 30 seconds
    const interval = setInterval(loadData, 30000);
    return () => clearInterval(interval);
  }, []);
  
  const handleSelectClient = useCallback(async (clientId) => {
    setSelectedClientId(clientId);
    setActivePage('client-detail');
    try {
      const clientData = await api.getClientDetails(clientId);
      setClient(clientData);
    } catch (error) {
      console.error('Failed to load client details:', error);
    }
  }, []);
  
  const handleSelectPage = (page) => {
    setActivePage(page);
    setSelectedClientId(null);
    setClient(null);
  };
  
  const handleSearch = (term) => {
    if (!term) {
      setFilteredClients(allClients);
    } else {
      setFilteredClients(
        allClients.filter(c => 
          c.name.toLowerCase().includes(term.toLowerCase()) || 
          c.id.toLowerCase().includes(term.toLowerCase())
        )
      );
    }
  };

  const [activeTab, setActiveTab] = useState('overview');

  const renderAdminContent = () => {
    if (activePage === 'overview') {
      return <AdminOverview />;
    }
    
    if (activePage === 'client-detail' && client) {
      return (
        <div>
          <div className="bg-white p-4 rounded-lg shadow-md mb-6">
            <h2 className="text-2xl font-bold text-gray-800">{client.name}</h2>
            <p className="text-sm text-gray-500 font-mono">{client.id}</p>
            <div className="flex space-x-6 mt-4 pt-4 border-t">
              <div className="text-sm">
                <p className="text-gray-500">Agents</p>
                <p className="font-semibold text-lg">{client.agentsOnline} / {client.agentsTotal}</p>
              </div>
              <div className="text-sm">
                <p className="text-gray-500">Instances</p>
                <p className="font-semibold text-lg">{client.instances}</p>
              </div>
              <div className="text-sm">
                <p className="text-gray-500">Total Savings</p>
                <p className="font-semibold text-lg text-green-600">{client.totalSavings.toLocaleString('en-US', { style: 'currency', currency: 'USD' })}</p>
              </div>
              <div className="text-sm">
                <p className="text-gray-500">Last Sync</p>
                <p className="font-semibold text-lg">{client.lastSync ? new Date(client.lastSync).toLocaleString() : 'Never'}</p>
              </div>
            </div>
          </div>
          
          <div className="mb-4 border-b border-gray-200">
            <nav className="flex -mb-px space-x-6">
              {['Overview', 'Instances', 'Agents', 'Savings', 'Switch History', 'Events'].map(tab => {
                const tabId = tab.toLowerCase().replace(' ', '');
                return (
                  <button
                    key={tabId}
                    onClick={() => setActiveTab(tabId)}
                    className={`pb-3 px-1 text-sm font-medium ${
                      activeTab === tabId
                        ? 'border-b-2 border-blue-500 text-blue-600'
                        : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'
                    }`}
                  >
                    {tab}
                  </button>
                )
              })}
            </nav>
          </div>
          
          <div>
            {activeTab === 'overview' && <ClientOverviewTab clientId={client.id} />}
            {activeTab === 'agents' && <ClientAgentsTab clientId={client.id} />}
            {activeTab === 'instances' && <ClientInstancesTab clientId={client.id} />}
            {activeTab === 'savings' && <ClientSavingsTab clientId={client.id} />}
            {activeTab === 'switchhistory' && <ClientSwitchHistoryTab clientId={client.id} />}
            {activeTab === 'events' && <div className="p-4 bg-white rounded-lg shadow-md">
              <h3 className="text-lg font-semibold text-gray-800 mb-4">Events & Alerts</h3>
              <p className="text-gray-500">Events data would be shown here.</p>
            </div>}
          </div>
        </div>
      );
    }
    
    if (activePage === 'clients') {
      return (
        <div className="bg-white p-4 rounded-lg shadow-md">
          <h3 className="text-lg font-semibold text-gray-800 mb-4">All Clients</h3>
          <div className="overflow-x-auto">
            <table className="min-w-full divide-y divide-gray-200">
              <thead className="bg-gray-50">
                <tr>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Client Name</th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Status</th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Agents</th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Instances</th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Total Savings</th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Last Sync</th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Actions</th>
                </tr>
              </thead>
              <tbody className="bg-white divide-y divide-gray-200">
                {filteredClients.map(c => (
                  <tr key={c.id} className="hover:bg-gray-50">
                    <td className="px-4 py-3 whitespace-nowrap">
                      <div className="text-sm font-medium text-gray-900">{c.name}</div>
                      <div className="text-xs text-gray-500 font-mono">{c.id}</div>
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap">
                      <span className={`px-2 py-1 text-xs rounded-full ${c.status === 'active' ? 'bg-green-100 text-green-800' : 'bg-red-100 text-red-800'}`}>
                        {c.status}
                      </span>
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-500">
                      {c.agentsOnline} / {c.agentsTotal}
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-500">{c.instances}</td>
                    <td className="px-4 py-3 whitespace-nowrap text-sm font-medium text-green-600">
                      {c.totalSavings.toLocaleString('en-US', { style: 'currency', currency: 'USD' })}
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-500">
                      {c.lastSync ? new Date(c.lastSync).toLocaleString() : 'Never'}
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap text-sm">
                      <button
                        onClick={() => handleSelectClient(c.id)}
                        className="text-blue-600 hover:text-blue-800 font-medium"
                      >
                        View Details
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      );
    }
    
    return <div className="p-4 bg-white rounded-lg shadow-md text-2xl font-semibold">{activePage} Page (Coming Soon)</div>;
  };
  
  return (
    <div className="flex h-screen bg-gray-100">
      <AdminSidebar
        clients={filteredClients}
        onSelectClient={handleSelectClient}
        activeClientId={selectedClientId}
        onSelectPage={handleSelectPage}
        activePage={activePage}
      />
      <div className="flex-1 flex flex-col ml-64">
        <AdminHeader stats={globalStats} onSearch={handleSearch} />
        <main className="flex-1 p-6 overflow-y-auto">
          {loading ? (
            <div className="flex justify-center items-center h-full"><LoadingSpinner size="lg" /></div>
          ) : (
            renderAdminContent()
          )}
        </main>
      </div>
    </div>
  );
};

// ==============================================================================
// APP ROOT
// ==============================================================================

export default function App() {
  return (
    <div className="font-inter">
      <AdminDashboardApp />
    </div>
  );
}
