import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import { ContactList } from '../contact-list';
import type { ContactCard } from '@/lib/jmap/types';

function makeContact(overrides: Partial<ContactCard> & { id: string }): ContactCard {
  return {
    addressBookIds: {},
    ...overrides,
  };
}

const alice = makeContact({
  id: '1',
  name: { components: [{ kind: 'given', value: 'Alice' }, { kind: 'surname', value: 'Smith' }], isOrdered: true },
  emails: { e0: { address: 'alice@example.com' } },
});

const bob = makeContact({
  id: '2',
  name: { components: [{ kind: 'given', value: 'Bob' }, { kind: 'surname', value: 'Jones' }], isOrdered: true },
  emails: { e0: { address: 'bob@example.com' } },
});

const group = makeContact({
  id: '3',
  kind: 'group',
  name: { components: [{ kind: 'given', value: 'Team' }], isOrdered: true },
  members: { '1': true },
});

const defaultProps = {
  contacts: [alice, bob],
  selectedContactId: null,
  searchQuery: '',
  onSearchChange: vi.fn(),
  onSelectContact: vi.fn(),
  onCreateNew: vi.fn(),
  supportsSync: true,
  selectedContactIds: new Set<string>(),
  onToggleSelection: vi.fn(),
  onSelectAll: vi.fn(),
  onClearSelection: vi.fn(),
  onBulkDelete: vi.fn(),
  onBulkAddToGroup: vi.fn(),
  onBulkExport: vi.fn(),
  groups: [],
};

describe('ContactList', () => {
  it('renders contact names', () => {
    render(<ContactList {...defaultProps} />);
    expect(screen.getByText('Alice Smith')).toBeInTheDocument();
    expect(screen.getByText('Bob Jones')).toBeInTheDocument();
  });

  it('filters contacts by search query', () => {
    render(<ContactList {...defaultProps} searchQuery="alice" />);
    expect(screen.getByText('Alice Smith')).toBeInTheDocument();
    expect(screen.queryByText('Bob Jones')).not.toBeInTheDocument();
  });

  it('shows empty state when no contacts match', () => {
    render(<ContactList {...defaultProps} contacts={[]} />);
    expect(screen.getByText('empty_state_title')).toBeInTheDocument();
  });

  it('shows search empty state when search has no results', () => {
    render(<ContactList {...defaultProps} searchQuery="zzz" />);
    expect(screen.getByText('empty_search')).toBeInTheDocument();
  });

  it('shows local mode banner when supportsSync is false', () => {
    render(<ContactList {...defaultProps} supportsSync={false} />);
    expect(screen.getByText('local_mode')).toBeInTheDocument();
  });

  it('hides local mode banner when supportsSync is true', () => {
    render(<ContactList {...defaultProps} supportsSync={true} />);
    expect(screen.queryByText('local_mode')).not.toBeInTheDocument();
  });

  it('calls onCreateNew when create button is clicked', () => {
    const onCreateNew = vi.fn();
    render(<ContactList {...defaultProps} onCreateNew={onCreateNew} />);
    fireEvent.click(screen.getByText('create_new'));
    expect(onCreateNew).toHaveBeenCalledOnce();
  });

  it('shows bulk action bar when contacts are selected', () => {
    render(<ContactList {...defaultProps} selectedContactIds={new Set(['1'])} />);
    expect(screen.getByText('bulk.selected')).toBeInTheDocument();
    expect(screen.getByTestId('contact-bulk-actions-trigger')).toBeInTheDocument();
  });

  it('excludes groups from the list', () => {
    render(<ContactList {...defaultProps} contacts={[alice, bob, group]} />);
    expect(screen.getByText('Alice Smith')).toBeInTheDocument();
    expect(screen.queryByText('Team')).not.toBeInTheDocument();
  });
});
