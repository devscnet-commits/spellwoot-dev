import { useConversationRequiredAttributes } from '../useConversationRequiredAttributes';
import { useMapGetter } from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';

vi.mock('dashboard/composables/store');
vi.mock('dashboard/composables/useAccount');

const defaultAttributes = [
  {
    attributeKey: 'priority',
    attributeDisplayName: 'Priority',
    attributeDisplayType: 'list',
    attributeValues: ['High', 'Medium', 'Low'],
  },
  {
    attributeKey: 'category',
    attributeDisplayName: 'Category',
    attributeDisplayType: 'text',
    attributeValues: [],
  },
  {
    attributeKey: 'is_urgent',
    attributeDisplayName: 'Is Urgent',
    attributeDisplayType: 'checkbox',
    attributeValues: [],
  },
];

describe('useConversationRequiredAttributes', () => {
  beforeEach(() => {
    useMapGetter.mockImplementation(getter => {
      if (getter === 'accounts/isFeatureEnabledonAccount') {
        return { value: () => true };
      }
      if (getter === 'attributes/getConversationAttributes') {
        return { value: defaultAttributes };
      }
      return { value: null };
    });

    useAccount.mockReturnValue({
      currentAccount: {
        value: {
          settings: {
            conversation_required_attributes: [
              'priority',
              'category',
              'is_urgent',
            ],
          },
        },
      },
      accountId: { value: 1 },
    });
  });

  const setupMocks = (
    requiredAttributes = ['priority', 'category', 'is_urgent'],
    { attributes = defaultAttributes, featureEnabled = true } = {}
  ) => {
    useMapGetter.mockImplementation(getter => {
      if (getter === 'accounts/isFeatureEnabledonAccount') {
        return { value: () => featureEnabled };
      }
      if (getter === 'attributes/getConversationAttributes') {
        return { value: attributes };
      }
      return { value: null };
    });

    useAccount.mockReturnValue({
      currentAccount: {
        value: {
          settings: {
            conversation_required_attributes: requiredAttributes,
          },
        },
      },
      accountId: { value: 1 },
    });
  };

  describe('requiredAttributeKeys', () => {
    it('should return required attribute keys from account settings', () => {
      setupMocks();
      const { requiredAttributeKeys } = useConversationRequiredAttributes();

      expect(requiredAttributeKeys.value).toEqual([
        'priority',
        'category',
        'is_urgent',
      ]);
    });

    it('should return empty array when no required attributes configured', () => {
      setupMocks([]);
      const { requiredAttributeKeys } = useConversationRequiredAttributes();

      expect(requiredAttributeKeys.value).toEqual([]);
    });

    it('should return empty array when account settings is null', () => {
      setupMocks([], { attributes: [] });
      useAccount.mockReturnValue({
        currentAccount: { value: { settings: null } },
        accountId: { value: 1 },
      });

      const { requiredAttributeKeys } = useConversationRequiredAttributes();

      expect(requiredAttributeKeys.value).toEqual([]);
    });
  });

  describe('requiredAttributes', () => {
    it('should return full attribute definitions for required attributes only', () => {
      setupMocks();
      const { requiredAttributes } = useConversationRequiredAttributes();

      expect(requiredAttributes.value).toHaveLength(3);
      expect(requiredAttributes.value[0]).toMatchObject({
        attributeKey: 'priority',
        attributeDisplayName: 'Priority',
        attributeDisplayType: 'list',
        attributeValues: ['High', 'Medium', 'Low'],
        value: 'priority',
        label: 'Priority',
        type: 'list',
        key: 'priority',
        rule: 'always',
      });
    });

    it('should filter out deleted attributes that no longer exist', () => {
      // Mock with only 2 attributes available but 3 required
      setupMocks(['priority', 'category', 'is_urgent'], {
        attributes: [
          {
            attributeKey: 'priority',
            attributeDisplayName: 'Priority',
            attributeDisplayType: 'list',
            attributeValues: ['High', 'Medium', 'Low'],
          },
          {
            attributeKey: 'is_urgent',
            attributeDisplayName: 'Is Urgent',
            attributeDisplayType: 'checkbox',
            attributeValues: [],
          },
        ],
      });

      const { requiredAttributes } = useConversationRequiredAttributes();

      expect(requiredAttributes.value).toHaveLength(2);
      expect(requiredAttributes.value.map(attr => attr.value)).toEqual([
        'priority',
        'is_urgent',
      ]);
    });
  });

  describe('checkMissingAttributes', () => {
    beforeEach(() => {
      setupMocks();
    });

    it('should return no missing when all attributes are filled', () => {
      const { checkMissingAttributes } = useConversationRequiredAttributes();

      const customAttributes = {
        priority: 'High',
        category: 'Bug Report',
        is_urgent: true,
      };

      const result = checkMissingAttributes(customAttributes);

      expect(result.hasMissing).toBe(false);
      expect(result.missing).toEqual([]);
      expect(result.all).toHaveLength(3);
    });

    it('should detect missing text attributes', () => {
      const { checkMissingAttributes } = useConversationRequiredAttributes();

      const customAttributes = {
        priority: 'High',
        is_urgent: true,
        // category is missing
      };

      const result = checkMissingAttributes(customAttributes);

      expect(result.hasMissing).toBe(true);
      expect(result.missing).toHaveLength(1);
      expect(result.missing[0].value).toBe('category');
    });

    it('should detect empty string values as missing', () => {
      const { checkMissingAttributes } = useConversationRequiredAttributes();

      const customAttributes = {
        priority: 'High',
        category: '', // empty string
        is_urgent: true,
      };

      const result = checkMissingAttributes(customAttributes);

      expect(result.hasMissing).toBe(true);
      expect(result.missing[0].value).toBe('category');
    });

    it('should consider checkbox attribute present when value is true', () => {
      const { checkMissingAttributes } = useConversationRequiredAttributes();

      const customAttributes = {
        priority: 'High',
        category: 'Bug Report',
        is_urgent: true,
      };

      const result = checkMissingAttributes(customAttributes);

      expect(result.hasMissing).toBe(false);
      expect(result.missing).toEqual([]);
    });

    it('should consider checkbox attribute present when value is false', () => {
      const { checkMissingAttributes } = useConversationRequiredAttributes();

      const customAttributes = {
        priority: 'High',
        category: 'Bug Report',
        is_urgent: false, // false is still considered "filled"
      };

      const result = checkMissingAttributes(customAttributes);

      expect(result.hasMissing).toBe(false);
      expect(result.missing).toEqual([]);
    });

    it('should detect missing checkbox when key does not exist', () => {
      const { checkMissingAttributes } = useConversationRequiredAttributes();

      const customAttributes = {
        priority: 'High',
        category: 'Bug Report',
        // is_urgent key is completely missing
      };

      const result = checkMissingAttributes(customAttributes);

      expect(result.hasMissing).toBe(true);
      expect(result.missing).toHaveLength(1);
      expect(result.missing[0].value).toBe('is_urgent');
      expect(result.missing[0].type).toBe('checkbox');
    });

    it('should handle falsy values correctly for non-checkbox attributes', () => {
      setupMocks(['score', 'status_flag'], {
        attributes: [
          {
            attributeKey: 'score',
            attributeDisplayName: 'Score',
            attributeDisplayType: 'number',
            attributeValues: [],
          },
          {
            attributeKey: 'status_flag',
            attributeDisplayName: 'Status Flag',
            attributeDisplayType: 'text',
            attributeValues: [],
          },
        ],
      });

      const { checkMissingAttributes } = useConversationRequiredAttributes();

      const customAttributes = {
        score: 0, // zero should be considered valid, not missing
        status_flag: false, // false should be considered valid, not missing
      };

      const result = checkMissingAttributes(customAttributes);

      expect(result.hasMissing).toBe(false);
      expect(result.missing).toEqual([]);
    });

    it('should handle null values as missing for text attributes', () => {
      const { checkMissingAttributes } = useConversationRequiredAttributes();

      const customAttributes = {
        priority: 'High',
        category: null, // null should be missing for text attribute
        is_urgent: true, // checkbox is present
      };

      const result = checkMissingAttributes(customAttributes);

      expect(result.hasMissing).toBe(true);
      expect(result.missing).toHaveLength(1);
      expect(result.missing[0].value).toBe('category');
    });

    it('should consider undefined checkbox values as present when key exists', () => {
      const { checkMissingAttributes } = useConversationRequiredAttributes();

      const customAttributes = {
        priority: 'High',
        category: 'Bug Report',
        is_urgent: undefined, // key exists but value is undefined - still considered "filled" for checkbox
      };

      const result = checkMissingAttributes(customAttributes);

      expect(result.hasMissing).toBe(false);
      expect(result.missing).toEqual([]);
    });

    it('should return no missing when no attributes are required', () => {
      setupMocks([]); // No required attributes

      const { checkMissingAttributes } = useConversationRequiredAttributes();

      const result = checkMissingAttributes({});

      expect(result.hasMissing).toBe(false);
      expect(result.missing).toEqual([]);
    });

    it('should skip conditional attribute when condition is not met', () => {
      setupMocks(
        [
          { key: 'status', rule: 'always' },
          {
            key: 'sale_value',
            rule: 'conditional',
            condition_field: 'status',
            condition_value: 'Won',
          },
          {
            key: 'loss_reason',
            rule: 'conditional',
            condition_field: 'status',
            condition_value: 'Lost',
          },
        ],
        {
          attributes: [
            {
              attributeKey: 'status',
              attributeDisplayName: 'Status',
              attributeDisplayType: 'list',
              attributeValues: ['Won', 'Lost'],
            },
            {
              attributeKey: 'sale_value',
              attributeDisplayName: 'Sale Value',
              attributeDisplayType: 'number',
              attributeValues: [],
            },
            {
              attributeKey: 'loss_reason',
              attributeDisplayName: 'Loss Reason',
              attributeDisplayType: 'text',
              attributeValues: [],
            },
          ],
        }
      );

      const { checkMissingAttributes } = useConversationRequiredAttributes();

      // status = Won → sale_value is required, loss_reason is not
      const resultWon = checkMissingAttributes({ status: 'Won' });
      expect(resultWon.hasMissing).toBe(true);
      expect(resultWon.missing.map(a => a.value)).toEqual(['sale_value']);

      // status = Lost → loss_reason is required, sale_value is not
      const resultLost = checkMissingAttributes({ status: 'Lost' });
      expect(resultLost.hasMissing).toBe(true);
      expect(resultLost.missing.map(a => a.value)).toEqual(['loss_reason']);

      // status empty → no conditional required
      const resultEmpty = checkMissingAttributes({});
      expect(resultEmpty.hasMissing).toBe(true);
      expect(resultEmpty.missing.map(a => a.value)).toEqual(['status']);
    });

    it('should handle whitespace-only values as missing', () => {
      const { checkMissingAttributes } = useConversationRequiredAttributes();

      const customAttributes = {
        priority: 'High',
        category: '   ', // whitespace only
        is_urgent: true,
      };

      const result = checkMissingAttributes(customAttributes);

      expect(result.hasMissing).toBe(true);
      expect(result.missing[0].value).toBe('category');
    });
  });
});
