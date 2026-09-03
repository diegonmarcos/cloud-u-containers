import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import { ContactListItem } from '../contact-list-item';
import type { ContactCard } from '@/lib/jmap/types';

const contact: ContactCard = {
  id: '1',
  addressBookIds: {},
  name: { components: [{ kind: 'given', value: 'Alice' }, { kind: 'surname', value: 'Smith' }], isOrdered: true },
  emails: { e0: { address: 'alice@example.com' } },
  organizations: { o0: { name: 'Acme Corp' } },
};

const noNameContact: ContactCard = {
  id: '2',
  addressBookIds: {},
  emails: { e0: { address: 'nobody@example.com' } },
};

const _emptyContact: ContactCard = {
  id: '3',
  addressBookIds: {},
};

describe('ContactListItem', () => {
  it('renders contact name and email', () => {
    render(<ContactListItem contact={contact} isSelected={false} onClick={vi.fn()} />);
    expect(screen.getByText('Alice Smith')).toBeInTheDocument();
    expect(screen.getByText('alice@example.com')).toBeInTheDocument();
  });

  it('renders organization', () => {
    render(<ContactListItem contact={contact} isSelected={false} onClick={vi.fn()} />);
    expect(screen.getByText('Acme Corp')).toBeInTheDocument();
  });

  it('applies selected styling', () => {
    const { container } = render(<ContactListItem contact={contact} isSelected={true} onClick={vi.fn()} />);
    const button = container.querySelector('button');
    expect(button?.className).toContain('bg-accent');
  });

  it('shows email as display name when no name exists', () => {
    render(<ContactListItem contact={noNameContact} isSelected={false} onClick={vi.fn()} />);
    const matches = screen.getAllByText('nobody@example.com');
    expect(matches.length).toBeGreaterThanOrEqual(1);
  });

  it('calls onClick when clicked', () => {
    const onClick = vi.fn();
    render(<ContactListItem contact={contact} isSelected={false} onClick={onClick} />);
    fireEvent.click(screen.getByText('Alice Smith'));
    expect(onClick).toHaveBeenCalledOnce();
  });
});
